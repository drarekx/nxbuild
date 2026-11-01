import AppKit
import SwiftUI
import CryptoKit
import Observation

/// Se actualiza sola desde las versiones de GitHub (como Wallpy).
///
/// Cada versión publica `NXBuild.zip` (con «NX Build.app» dentro) y `NXBuild.zip.sha256`. La actualización se descarga,
/// se comprueba con su huella y su Info.plist, y un shell aparte espera a que la app salga, cambia el bundle y la reabre.
/// Si el repositorio es privado, GitHub no responde sin sesión: se usa el token de `gh auth token` (si gh está instalado
/// y con sesión iniciada), y los archivos se bajan por la API con ese token.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    nonisolated static let repo = "drarekx/nxbuild"
    nonisolated static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/drarekx/nxbuild/main/install.sh | bash"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    enum State: Equatable { case idle, checking, downloading, installing }

    private(set) var state: State = .idle
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    var autoCheck: Bool {
        get { access(keyPath: \.autoCheck); return defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set { withMutation(keyPath: \.autoCheck) { defaults.set(newValue, forKey: "autoCheckUpdates") } }
    }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    /// Solo una app empaquetada se puede actualizar (no `swift run`).
    var canUpdate: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    struct Release: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
            let url: URL                    // API (con token: Accept application/octet-stream)
            let browser_download_url: URL   // público
        }
        let tag_name: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        func asset(_ name: String) -> Asset? { assets.first { $0.name == name } }
    }

    /// Comprobaciones en segundo plano: poco después de abrir y luego una vez al día.
    func start() {
        guard canUpdate else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard autoCheck else { return }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        Task { await check(userInitiated: false) }
    }

    /// `userInitiated`: también avisa de «estás al día» y de errores, y no hace caso de las versiones omitidas.
    func check(userInitiated: Bool) async {
        guard state == .idle else { return }
        guard canUpdate else {
            if userInitiated { alert("No se puede actualizar", "Esta copia no es una app empaquetada.") }
            return
        }
        state = .checking
        defer { if state == .checking { state = .idle } }
        do {
            let token = await Task.detached { Self.ghToken() }.value
            let release = try await Self.latest(token: token)
            defaults.set(Date(), forKey: "lastUpdateCheck")
            guard !release.draft, !release.prerelease,
                  Self.compare(release.version, Self.currentVersion) == .orderedDescending else {
                if userInitiated { alert("NX Build está al día", "Tienes la última versión (\(Self.currentVersion)).") }
                return
            }
            if !userInitiated, defaults.string(forKey: "skippedVersion") == release.version { return }
            state = .idle
            offer(release, token: token)
        } catch {
            if userInitiated { alert("No se pudo buscar actualizaciones", error.localizedDescription) }
        }
    }

    private nonisolated static func latest(token: String?) async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("NXBuild/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: req)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return try JSONDecoder().decode(Release.self, from: data)
        case 404: throw UpdateError.notFound(hasToken: token != nil)
        default: throw UpdateError.server
        }
    }

    /// Descarga un archivo de la versión: por la API con token (repo privado) o por su enlace público.
    private nonisolated static func download(_ asset: Release.Asset, token: String?) async throws -> URL {
        var req: URLRequest
        if let token {
            req = URLRequest(url: asset.url)
            req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            req = URLRequest(url: asset.browser_download_url)
        }
        req.setValue("NXBuild/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
        return file
    }

    /// El token de la sesión de gh, si hay gh y sesión. Nunca se guarda ni se escribe en ningún log.
    nonisolated static func ghToken() -> String? {
        for gh in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: gh) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gh)
            p.arguments = ["auth", "token"]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let t = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, !t.isEmpty { return t }
        }
        return nil
    }

    private func offer(_ release: Release, token: String?) {
        let a = NSAlert()
        a.messageText = "NX Build \(release.version) está disponible"
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 900 { notes = String(notes.prefix(900)) + "…" }
        a.informativeText = "Tienes la versión \(Self.currentVersion)." + (notes.isEmpty ? "" : "\n\n\(notes)")
        a.addButton(withTitle: "Actualizar ahora")
        a.addButton(withTitle: "Más tarde")
        a.addButton(withTitle: "Omitir esta versión")
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: Task { await install(release, token: token) }
        case .alertThirdButtonReturn: defaults.set(release.version, forKey: "skippedVersion")
        default: break
        }
    }

    // MARK: - Instalar

    private func install(_ release: Release, token: String?) async {
        if BuildRunner.active?.isRunning == true {
            alert("Hay una build en marcha", "Actualiza cuando termine: al actualizar, la app se cierra.")
            return
        }
        let appURL = Bundle.main.bundleURL
        let parent = appURL.deletingLastPathComponent()
        guard !appURL.path.contains("/AppTranslocation/") else {
            alert("No se puede actualizar desde aquí", "Mueve NX Build a la carpeta Aplicaciones, ábrela de nuevo y vuelve a intentarlo.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            alert("No se puede actualizar", "No hay permiso para escribir en \(parent.path).\nUsa el instalador:\n\n\(Self.installCommand)")
            return
        }
        guard let zipAsset = release.asset("NXBuild.zip"), let hashAsset = release.asset("NXBuild.zip.sha256") else {
            alert("No se puede actualizar", "La versión \(release.version) no trae los archivos de actualización.")
            return
        }

        state = .downloading
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("NXBuild-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("NXBuild.zip")
            try fm.moveItem(at: try await Self.download(zipAsset, token: token), to: zip)
            let hashFile = try await Self.download(hashAsset, token: token)
            let expected = String(decoding: try Data(contentsOf: hashFile), as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard !expected.isEmpty, expected == actual else { throw UpdateError.checksum }

            state = .installing
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let newApp = work.appendingPathComponent("NX Build.app")
            guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info["CFBundleShortVersionString"] as? String == release.version else {
                throw UpdateError.invalidBundle
            }
            relaunch(replacing: appURL, with: newApp, cleanup: work)
        } catch {
            state = .idle
            try? fm.removeItem(at: work)
            alert("La actualización falló", error.localizedDescription)
        }
    }

    /// Shell aparte: espera a que salgamos, cambia los bundles (con copia hasta que el cambio sale bien) y reabre.
    private func relaunch(replacing appURL: URL, with newApp: URL, cleanup work: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        backup="$1.old-$$"
        mv "$1" "$backup" && mv "$2" "$1" && rm -rf "$backup" || { [ -d "$backup" ] && mv "$backup" "$1"; }
        xattr -dr com.apple.quarantine "$1" 2>/dev/null
        rm -rf "$3"
        open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "nxbuild-update", appURL.path, newApp.path, work.path]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .idle
            alert("La actualización falló", error.localizedDescription)
        }
    }

    private func run(_ path: String, _ arguments: [String]) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { p in
                p.terminationStatus == 0 ? c.resume() : c.resume(throwing: UpdateError.unzip)
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }

    /// Versiones con puntos comparadas por número («1.10.0» > «1.9.2»).
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let l = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let r = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(l.count, r.count) {
            let x = i < l.count ? l[i] : 0, y = i < r.count ? r[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        NSApp.activate()
        a.runModal()
    }
}

enum UpdateError: LocalizedError {
    case server, notFound(hasToken: Bool), checksum, unzip, invalidBundle

    var errorDescription: String? {
        switch self {
        case .server: "GitHub no respondió bien. Inténtalo más tarde."
        case .notFound(let hasToken):
            hasToken ? "No hay ninguna versión publicada todavía."
                     : "GitHub no la encuentra: el repositorio es privado. Instala gh e inicia sesión (gh auth login) o haz público el repositorio."
        case .checksum: "El archivo descargado no coincide con su huella SHA-256. No se ha instalado nada."
        case .unzip: "No se pudo descomprimir la actualización."
        case .invalidBundle: "La descarga no contiene una versión válida de NX Build."
        }
    }
}

/// Menú NX Build › Buscar actualizaciones…
struct CheckUpdatesButton: View {
    var body: some View {
        Button(Updater.shared.state == .idle ? "Buscar actualizaciones…" : "Buscando actualizaciones…") {
            Task { await Updater.shared.check(userInitiated: true) }
        }
        .disabled(Updater.shared.state != .idle || !Updater.shared.canUpdate)
    }
}

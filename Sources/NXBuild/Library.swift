import Foundation
import AppKit
import Observation

/// Un juego de Mac construido por nxnative (dm/mac/pack_app.py): un .app con bundle ID org.nxnative.<title ID> o
/// con las claves DM* en su Info.plist.
struct LibraryGame: Identifiable, Equatable, Sendable {
    var path: String
    var name: String
    var titleID: String
    var bundleID: String
    var version: String
    var commit: String
    var builtAt: Date?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var hasLaunchSettings: Bool {
        FileManager.default.fileExists(atPath: path + "/Contents/Resources/dm/launcher.json")
    }
    /// dm/mac/launcher.c: ~/Library/Logs/nxnative/<title ID>.log
    var logURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/nxnative/\(titleID).log")
    }
    /// DLC metidos en la app: Contents/Resources/aoc/<índice>/ (launcher.c → DM_AOC_DIR).
    var dlcCount: Int {
        let aoc = path + "/Contents/Resources/aoc"
        return ((try? FileManager.default.contentsOfDirectory(atPath: aoc)) ?? []).filter { !$0.hasPrefix(".") }.count
    }
    /// ~/Library/Application Support/nxnative/<title ID>/save
    var saveURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/nxnative/\(titleID)/save")
    }

    /// Copiada de otro Mac (AirDrop, descarga, zip): macOS le pone com.apple.quarantine y, como la app solo tiene firma
    /// ad hoc (sin notarizar), Gatekeeper no deja abrirla.
    var isQuarantined: Bool { Quarantine.isSet(path) }

    /// LSMinimumSystemVersion que pone nxnative al construir (p. ej. 26.6) si este Mac tiene una versión anterior.
    var requiredSystemIfNewer: String? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let min = info["LSMinimumSystemVersion"] as? String else { return nil }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let mine = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return Updater.compare(min, mine) == .orderedDescending ? min : nil
    }

    static func read(_ app: URL) -> LibraryGame? {
        guard app.pathExtension == "app",
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let bid = info["CFBundleIdentifier"] as? String else { return nil }
        let isNX = bid.hasPrefix("org.nxnative.") || info["DMCommit"] != nil || info["DMChain"] != nil
        guard isNX else { return nil }
        var tid = bid.hasPrefix("org.nxnative.") ? String(bid.dropFirst("org.nxnative.".count)).uppercased() : ""
        if tid.count != 16, let f = LaunchSettingsFile.load(app: app), let g = f.game { tid = g.uppercased() }
        let exe = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(info["CFBundleExecutable"] as? String ?? "")
        let built = (try? exe.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return LibraryGame(path: app.path,
                           name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent,
                           titleID: tid, bundleID: bid,
                           version: info["CFBundleShortVersionString"] as? String ?? "",
                           commit: info["DMCommit"] as? String ?? "", builtAt: built)
    }
}

/// La biblioteca: las apps de juego que hay en las carpetas de juegos (hasta 4 niveles, sin entrar en apps, carpetas
/// de build ni archivos extraídos). Las carpetas se guardan en library.json; las apps nunca se mueven ni copian.
@MainActor @Observable
final class GameLibrary {
    var folders: [String] = []
    var games: [LibraryGame] = []
    var scanning = false

    static var fileURL: URL { Dependencies.venvDir.deletingLastPathComponent().appendingPathComponent("library.json") }

    private struct Stored: Codable { var folders: [String] }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            folders = s.folders
        } else {
            folders = [GameStaging.root.path]
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Stored(folders: folders)).write(to: Self.fileURL)
    }

    func addFolder(_ path: String) {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !folders.contains(p) else { return }
        folders.append(p); save()
    }

    func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }; save()
    }

    func refresh() async {
        scanning = true
        let roots = folders
        let found = await Task.detached { Self.scan(roots) }.value
        games = found
        scanning = false
    }

    /// Las apps de juego bajo estas carpetas. Una carpeta en un disco que no está (el NAS) se salta sin más.
    nonisolated static func scan(_ roots: [String], maxDepth: Int = 4) -> [LibraryGame] {
        let fm = FileManager.default
        var out: [LibraryGame] = [], seen = Set<String>()
        func walk(_ dir: URL, _ depth: Int) {
            guard depth <= maxDepth,
                  let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            for u in items {
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard v?.isDirectory == true, v?.isSymbolicLink != true else { continue }
                let n = u.lastPathComponent
                if u.pathExtension == "app" {
                    if let g = LibraryGame.read(u), seen.insert(g.path).inserted { out.append(g) }
                    continue
                }
                if n.hasSuffix("_build") || n == "build" || ["extract", "romfs", "shader", "pso", "nsp", "node_modules"].contains(n) { continue }
                walk(u, depth + 1)
            }
        }
        for r in roots where fm.fileExists(atPath: r) { walk(URL(fileURLWithPath: r), 0) }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Jugar: abre la app del juego. skipWindow pasa DM_LAUNCHER=0 (sin la ventana de ajustes del juego; las opciones
    /// guardadas se aplican igual).
    func play(_ g: LibraryGame, skipWindow: Bool) async throws {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if skipWindow { cfg.environment = ["DM_LAUNCHER": "0"] }
        _ = try await NSWorkspace.shared.openApplication(at: g.url, configuration: cfg)
    }

    /// A la Papelera (se puede recuperar). Las partidas no se tocan: están en ~/Library/Application Support/nxnative.
    func trash(_ g: LibraryGame) async throws {
        _ = try await NSWorkspace.shared.recycle([g.url])
        await refresh()
    }

    func isRunning(_ g: LibraryGame) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: g.bundleID).contains { !$0.isTerminated }
    }
}

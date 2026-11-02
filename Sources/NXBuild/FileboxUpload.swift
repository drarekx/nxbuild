import Foundation
import AppKit
import Observation
import CryptoKit
import NetFS

/// Subir a Filebox un juego construido: comprimirlo en .zip, copiarlo por SMB a la carpeta `entrada` del recurso
/// compartido de Filebox y pedir la importación (POST /v1/imports), siguiendo su estado hasta que el juego sale en la
/// colección. Para juegos grandes es mucho más rápido que subirlos por la web.
@MainActor @Observable
final class FileboxUploads {
    enum Phase: Equatable {
        case mounting
        case zipping(done: Int64, total: Int64)
        case copying(done: Int64, total: Int64, bytesPerSecond: Double)
        case importing(Int)
        case done(String?)          // id del juego en Filebox
        case failed(String)

        /// Paso y avance, para mostrarlo en pequeño (inicio).
        var short: String {
            switch self {
            case .mounting: "conectando"
            case .zipping(let d, let t): "comprimiendo \(t > 0 ? Int(Double(d) * 100 / Double(t)) : 0) %"
            case .copying(let d, let t, _): "subiendo \(t > 0 ? Int(Double(d) * 100 / Double(t)) : 0) %"
            case .importing(let p): "importando \(p) %"
            case .done: "subido"
            case .failed: "error"
            }
        }

        var isActive: Bool {
            switch self { case .done, .failed: false; default: true }
        }
    }

    static let defaultShare = "smb://NAS472058._smb._tcp.local/Juegos/filebox"
    /// Carpeta del proyecto en el recurso compartido (smb://servidor/recurso/carpeta).
    var shareURL: String { didSet { UserDefaults.standard.set(shareURL, forKey: "filebox.shareURL") } }
    /// Carpeta de entrada dentro de la del proyecto (la API la llama `entrada`).
    var inboxName: String { didSet { UserDefaults.standard.set(inboxName, forKey: "filebox.inboxName") } }
    /// Subcarpeta dentro de `entrada` donde dejar los zips (vacío: en la raíz de `entrada`).
    var subfolder: String { didSet { UserDefaults.standard.set(subfolder, forKey: "filebox.uploadSubfolder") } }
    /// Borrar el zip de este Mac cuando la importación termina bien.
    var deleteZipAfter: Bool { didSet { UserDefaults.standard.set(deleteZipAfter, forKey: "filebox.deleteUploadZip") } }

    private(set) var states: [String: Phase] = [:]     // ruta de la app → fase
    private var tasks: [String: Task<Void, Never>] = [:]
    private var speed: [String: (at: Date, bytes: Int64, bps: Double)] = [:]

    static var stagingDir: URL { GameStaging.root.appendingPathComponent("Subidas") }

    init() {
        let d = UserDefaults.standard
        shareURL = d.string(forKey: "filebox.shareURL") ?? Self.defaultShare
        inboxName = d.string(forKey: "filebox.inboxName") ?? "entrada"
        subfolder = d.string(forKey: "filebox.uploadSubfolder") ?? "NX Build"
        deleteZipAfter = d.object(forKey: "filebox.deleteUploadZip") as? Bool ?? true
    }

    var activeCount: Int { states.values.filter(\.isActive).count }
    func state(_ g: LibraryGame) -> Phase? { states[g.path] }

    /// Nombre del zip, que Filebox usa como título inicial del juego.
    nonisolated static func zipName(for g: LibraryGame) -> String {
        FileboxDownloads.safeName("\(g.name) (Mac)") + ".zip"
    }

    /// Ruta dentro de `entrada` que se manda a la API.
    nonisolated static func importPath(subfolder: String, name: String) -> String {
        let sub = subfolder.split(separator: "/").map { FileboxDownloads.safeName(String($0)) }.joined(separator: "/")
        return sub.isEmpty ? name : sub + "/" + name
    }

    func upload(_ g: LibraryGame, store: FileboxStore) {
        guard tasks[g.path] == nil else { return }
        let key = g.path
        let share = shareURL, inbox = inboxName, sub = subfolder, deleteAfter = deleteZipAfter
        states[key] = .mounting
        speed[key] = nil
        tasks[key] = Task {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                                 reason: "Subiendo \(g.name) a Filebox")
            defer { ProcessInfo.processInfo.endActivity(activity); tasks[key] = nil }
            do {
                let client = try store.client()
                // 1. La carpeta de entrada en el recurso compartido (lo monta si hace falta: macOS pide la contraseña).
                let project = try await SMBShare.folder(for: share)
                let inboxDir = project.appendingPathComponent(inbox)
                guard FileManager.default.fileExists(atPath: inboxDir.path) else {
                    throw Filebox.Failure.http(0, "no existe la carpeta «\(inbox)» en \(share)")
                }
                let name = Self.zipName(for: g)
                let rel = Self.importPath(subfolder: sub, name: name)
                let target = inboxDir.appendingPathComponent(rel)

                // 2. Comprimir en ~/NX Build/Subidas.
                states[key] = .zipping(done: 0, total: 0)
                let z = Self.stagingDir.appendingPathComponent(name)
                // Un zip de un intento anterior, más nuevo que la app, vale tal cual.
                let zipDate = (try? z.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if zipDate == nil || zipDate! < (g.builtAt ?? .distantFuture) {
                    try await Self.makeZip(of: g.url, to: z) { d, t in
                        Task { @MainActor in if case .zipping = self.states[key] { self.states[key] = .zipping(done: d, total: t) } }
                    }
                }

                // 3. Copiar al NAS calculando el sha256 a la vez.
                let total = (try? z.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
                states[key] = .copying(done: 0, total: total, bytesPerSecond: 0)
                let sha = try await Self.copy(z, to: target) { n in
                    Task { @MainActor in self.copied(key, n, total) }
                }

                // 4. Importar y esperar a que el servidor lo deje listo.
                states[key] = .importing(0)
                var imp = try await client.startImport(path: rel, size: total, sha256: sha)
                while imp.status == "transferring" {
                    states[key] = .importing(imp.progress)
                    try await Task.sleep(for: .seconds(2))
                    imp = try await client.importStatus(imp.id)
                }
                guard imp.status == "ready" else {
                    throw Filebox.Failure.http(0, "Filebox rechazó la importación: \(imp.failureReason ?? imp.status)")
                }
                states[key] = .done(imp.gameId)
                if deleteAfter { try? FileManager.default.removeItem(at: z) }
                await store.refresh()
            } catch is CancellationError {
                states[key] = nil
            } catch {
                states[key] = .failed(error.localizedDescription)
            }
        }
    }

    private func copied(_ key: String, _ done: Int64, _ total: Int64) {
        guard case .copying = states[key] else { return }
        let now = Date()
        var bps = speed[key]?.bps ?? 0
        if let s = speed[key] {
            let dt = now.timeIntervalSince(s.at)
            if dt >= 1 { bps = bps == 0 ? Double(done - s.bytes) / dt : bps * 0.7 + Double(done - s.bytes) / dt * 0.3; speed[key] = (now, done, bps) }
        } else { speed[key] = (now, done, 0) }
        states[key] = .copying(done: done, total: total, bytesPerSecond: bps)
    }

    /// Cancela lo que esté haciendo. Si ya se pidió la importación, el servidor sigue con ella.
    func cancel(_ g: LibraryGame) { tasks[g.path]?.cancel() }
    func clear(_ g: LibraryGame) { if let s = states[g.path], !s.isActive { states[g.path] = nil } }

    /// Comprueba la carpeta: la monta y mira que exista `entrada` y se pueda escribir. Devuelve la ruta local.
    func test() async throws -> String {
        let project = try await SMBShare.folder(for: shareURL)
        let inbox = project.appendingPathComponent(inboxName)
        guard FileManager.default.fileExists(atPath: inbox.path) else {
            throw Filebox.Failure.http(0, "montado en \(project.path), pero no hay carpeta «\(inboxName)»")
        }
        guard FileManager.default.isWritableFile(atPath: inbox.path) else {
            throw Filebox.Failure.http(0, "no se puede escribir en \(inbox.path)")
        }
        return inbox.path
    }

    // MARK: Pasos (fuera del hilo principal)

    /// ditto -c -k: zip con la app dentro (--keepParent), enlaces simbólicos intactos y sin atributos extendidos.
    /// Compresión rápida: los datos del juego ya vienen comprimidos.
    /// Avance: los bytes de los archivos terminados (líneas «N bytes for …» de -V, que ditto escribe a bloques) más por
    /// dónde va leyendo el archivo abierto (proc_pidfdinfo): casi todo el juego es un único romfs.img de varios GB.
    nonisolated static func makeZip(of app: URL, to zip: URL,
                                    progress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
            let total = max(1, logicalSize(of: app))
            if let free = FreeSpace.freeBytes(on: zip.deletingLastPathComponent()), free < total + 512_000_000 {
                throw Filebox.Failure.http(0, "no hay espacio para comprimirlo: hacen falta unos \(total.formatted(.byteCount(style: .file))) en \(zip.deletingLastPathComponent().path)")
            }
            let part = zip.appendingPathExtension("part")
            try? fm.removeItem(at: part)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "-V", "--keepParent", "--norsrc", "--noextattr", "--noacl",
                           "--zlibCompressionLevel", "1", app.path, part.path]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            let out = ZipOutput()
            pipe.fileHandleForReading.readabilityHandler = { h in out.feed(h.availableData) }
            try p.run()
            // El kernel da rutas reales (sin enlaces simbólicos: /private/var…), así que se compara con la real.
            let real = realPath(app.path)
            let parent = (real as NSString).deletingLastPathComponent + "/"
            var shown: Int64 = 0
            while p.isRunning {
                if Task.isCancelled { p.terminate() }
                var done = out.finishedBytes
                if let (path, offset) = openFile(of: p.processIdentifier, under: real + "/"),
                   !out.isFinished(String(path.dropFirst(parent.count))) {
                    done += offset
                }
                shown = max(shown, min(done, total))
                progress(shown, total)
                try? await Task.sleep(for: .milliseconds(400))
            }
            p.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            out.feed(pipe.fileHandleForReading.readDataToEndOfFile())
            if Task.isCancelled { try? fm.removeItem(at: part); throw CancellationError() }
            guard p.terminationStatus == 0 else {
                try? fm.removeItem(at: part)
                let e = out.errors
                throw Filebox.Failure.http(0, "no se pudo comprimir: " + (e.isEmpty ? "ditto terminó con \(p.terminationStatus)" : e))
            }
            try? fm.removeItem(at: zip)
            try fm.moveItem(at: part, to: zip)
            progress(total, total)
        }.value
    }

    nonisolated static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    /// El archivo que tiene abierto ese proceso bajo `prefix` y por qué byte va (su offset de lectura).
    nonisolated static func openFile(of pid: Int32, under prefix: String) -> (String, Int64)? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 4)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return nil }
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vi = vnode_fdinfowithpath()
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard r > 0, vi.pvip.vip_vi.vi_stat.vst_mode & S_IFMT == S_IFREG else { continue }   // solo archivos, no carpetas
            let path = withUnsafeBytes(of: vi.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if path.hasPrefix(prefix) { return (path, vi.pfi.fi_offset) }
        }
        return nil
    }

    /// Copia en bloques de 8 MB a «.<nombre>.part» junto al destino y la renombra al terminar (así el servidor nunca ve
    /// un zip a medias). Devuelve el sha256 de lo leído.
    nonisolated static func copy(_ src: URL, to dest: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let part = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".part")
            try? fm.removeItem(at: part)
            guard fm.createFile(atPath: part.path, contents: nil) else {
                throw Filebox.Failure.http(0, "no se puede escribir en \(dest.deletingLastPathComponent().path)")
            }
            let input = try FileHandle(forReadingFrom: src)
            let output = try FileHandle(forWritingTo: part)
            var hasher = SHA256()
            var done: Int64 = 0, last = Date.distantPast
            do {
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(data: chunk)
                    try output.write(contentsOf: chunk)
                    done += Int64(chunk.count)
                    if Date().timeIntervalSince(last) > 0.2 { progress(done); last = Date() }
                }
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                try? fm.removeItem(at: part)
                throw error is CancellationError ? error : Filebox.Failure.http(0, "la copia al NAS falló: \(error.localizedDescription)")
            }
            progress(done)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: part, to: dest)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Tamaño real de los datos (no lo que ocupa en disco: la RomFS son clones APFS).
    nonisolated static func logicalSize(of url: URL) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }
}

/// Recurso SMB: «smb://servidor/recurso/carpeta» → carpeta local, montando el recurso si no lo está.
enum SMBShare {
    struct Parts: Equatable {
        var server: URL         // smb://servidor/recurso
        var host: String
        var share: String
        var subpath: String     // carpeta dentro del recurso
    }

    static func parse(_ s: String) -> Parts? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), ["smb", "cifs"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host, !host.isEmpty else { return nil }
        let comps = u.path.split(separator: "/").map(String.init)
        guard let share = comps.first else { return nil }
        var root = URLComponents(); root.scheme = "smb"; root.host = host; root.user = u.user; root.path = "/" + share
        guard let server = root.url else { return nil }
        return Parts(server: server, host: host, share: share, subpath: comps.dropFirst().joined(separator: "/"))
    }

    /// «NAS472058._smb._tcp.local», «NAS472058.local» y «nas472058» son el mismo equipo.
    static func sameHost(_ a: String, _ b: String) -> Bool {
        func base(_ h: String) -> String { String(h.lowercased().split(separator: ".").first ?? "") }
        return base(a) == base(b)
    }

    /// Dónde está montado ese recurso, si lo está.
    static func mounted(_ p: Parts) -> URL? {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []) ?? []
        for v in vols {
            guard let r = (try? v.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting,
                  ["smb", "cifs"].contains(r.scheme?.lowercased() ?? ""), let h = r.host else { continue }
            let share = r.path.split(separator: "/").first.map(String.init)?.removingPercentEncoding ?? ""
            if sameHost(h, p.host), share.caseInsensitiveCompare(p.share) == .orderedSame { return v }
        }
        return nil
    }

    static func folder(for s: String) async throws -> URL {
        guard let p = parse(s) else {
            throw Filebox.Failure.http(0, "la carpeta compartida no es una dirección smb:// válida: \(s)")
        }
        let root: URL
        if let m = mounted(p) { root = m } else { root = try await mount(p) }
        let dir = p.subpath.isEmpty ? root : root.appendingPathComponent(p.subpath)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw Filebox.Failure.http(0, "el recurso está montado en \(root.path), pero no existe «\(p.subpath)»")
        }
        return dir
    }

    /// NetFS con interfaz: si hace falta usuario y contraseña, macOS los pide (y puede guardarlos en el Llavero).
    static func mount(_ p: Parts) async throws -> URL {
        let server = p.server
        return try await Task.detached(priority: .userInitiated) {
            let open = NSMutableDictionary()
            open[kNAUIOptionKey] = kNAUIOptionAllowUI
            var points: Unmanaged<CFArray>?
            let rc = NetFSMountURLSync(server as CFURL, nil, nil, nil, open, nil, &points)
            let list = points?.takeRetainedValue() as? [String] ?? []
            guard rc == 0, let first = list.first else {
                if rc == Int32(ECANCELED) || rc == -128 { throw CancellationError() }
                throw Filebox.Failure.http(0, "no se pudo montar \(server.absoluteString) (error \(rc)). Prueba a abrirlo en Finder › Ir › Conectarse al servidor.")
            }
            return URL(fileURLWithPath: first)
        }.value
    }
}

import SwiftUI

/// En el panel del juego: botón «Subir a Filebox» y, mientras sube, el paso, la barra y Cancelar.
struct FileboxUploadPanel: View {
    let game: LibraryGame
    @Environment(FileboxUploads.self) private var uploads
    @Environment(FileboxStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch uploads.state(game) {
            case nil:
                Button { uploads.upload(game, store: store) } label: {
                    Label("Subir a Filebox", systemImage: "arrow.up.circle").frame(maxWidth: .infinity)
                }
                .disabled(!store.isConfigured)
                .help(store.isConfigured ? "Comprime la app, la copia a la carpeta de entrada de Filebox y la importa"
                                         : "Configura Filebox en Ajustes (dirección y token)")
            case .mounting?:
                step("Conectando con la carpeta compartida…", nil)
                cancel
            case .zipping(let done, let total)?:
                let f = total > 0 ? Double(done) / Double(total) : 0
                step(total > 0 ? "Comprimiendo · \(done.formatted(.byteCount(style: .file))) de \(total.formatted(.byteCount(style: .file))) · \(Int(f * 100)) %" : "Comprimiendo…", total > 0 ? f : nil)
                cancel
            case .copying(let done, let total, let bps)?:
                let f = total > 0 ? Double(done) / Double(total) : 0
                step("Subiendo al NAS · \(done.formatted(.byteCount(style: .file))) de \(total.formatted(.byteCount(style: .file)))", f)
                HStack {
                    if bps > 0 {
                        Text("\(Int64(bps).formatted(.byteCount(style: .file)))/s · quedan \(Duration.seconds(Double(total - done) / bps).formatted(.units(allowed: [.hours, .minutes, .seconds], maximumUnitCount: 2)))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    cancel
                }
            case .importing(let p)?:
                step("Filebox lo está importando (comprueba el SHA-256) · \(p) %", Double(p) / 100)
                Text("Si cancelas aquí, el servidor termina la importación igualmente.").font(.caption).foregroundStyle(.secondary)
                cancel
            case .done?:
                Label("Subido: ya está en la colección de Filebox", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
                Button("Vale") { uploads.clear(game) }.buttonStyle(.link)
            case .failed(let msg)?:
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Reintentar") { uploads.clear(game); uploads.upload(game, store: store) }
                    Button("Cerrar") { uploads.clear(game) }
                }
            }
        }
    }

    private func step(_ text: String, _ fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.callout).monospacedDigit()
            if let fraction { ProgressView(value: min(1, max(0, fraction))) } else { ProgressView().progressViewStyle(.linear) }
        }
    }

    private var cancel: some View {
        Button("Cancelar", role: .cancel) { uploads.cancel(game) }.controlSize(.small)
    }
}

/// Salida de ditto -V leída mientras comprime: bytes de los archivos ya terminados, cuáles son, y los errores.
final class ZipOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = ""
    private var bytes: Int64 = 0
    private var done = Set<String>()
    private var errs = ""

    func feed(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let lines = (tail + String(decoding: d, as: UTF8.self)).components(separatedBy: "\n")
        tail = lines.last ?? ""
        for l in lines.dropLast() {
            // «12345 bytes for ./Juego.app/Contents/Resources/romfs.img»
            if let r = l.range(of: " bytes for "), let n = Int64(l[..<r.lowerBound].trimmingCharacters(in: .whitespaces)) {
                bytes += n
                var path = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("./") { path.removeFirst(2) }
                done.insert(path)
            } else if l.contains("ditto:"), errs.count < 2000 { errs += l + "\n" }
        }
    }
    var finishedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
    func isFinished(_ rel: String) -> Bool { lock.lock(); defer { lock.unlock() }; return done.contains(rel) }
    var errors: String { lock.lock(); defer { lock.unlock() }; return errs }
}

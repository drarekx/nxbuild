import Foundation
import CryptoKit
import Observation

/// Descarga una URL a un archivo .part, continuando desde lo que ya haya (Range: bytes=N-). Sirve aunque la URL
/// cambie entre intentos (los enlaces firmados de Filebox caducan): lo que cuenta es el .part.
/// Si el servidor ignora Range (200), empieza de cero. Respeta la cancelación de la tarea que la espera.
final class RangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case linkExpired(Int)
        case http(Int)
        case badRange(String)
        case noSpace(Int64)
        var errorDescription: String? {
            switch self {
            case .linkExpired(let c): "El enlace de descarga ya no vale (\(c))."
            case .http(let c): "El servidor respondió \(c) a la descarga."
            case .badRange(let m): "El servidor no continuó la descarga donde se quedó (\(m))."
            case .noSpace(let n): "No hay espacio: faltan \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) libres en el disco de descargas."
            }
        }
    }

    let url: URL, part: URL, expected: Int64
    private let configuration: URLSessionConfiguration
    private let onProgress: @Sendable (Int64) -> Void
    // Todo lo de abajo solo se toca desde la cola del delegado (serie), salvo antes de empezar.
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?
    private var cont: CheckedContinuation<Void, Error>?
    private var lastReport = Date.distantPast
    private var task: URLSessionDataTask?
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q }()

    init(url: URL, part: URL, expected: Int64, configuration: URLSessionConfiguration = .default,
         onProgress: @escaping @Sendable (Int64) -> Void) {
        self.url = url; self.part = part; self.expected = expected; self.configuration = configuration; self.onProgress = onProgress
    }

    static func size(_ u: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func run() async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        var have = Self.size(part)
        if expected > 0, have > expected { try FileHandle(forWritingTo: part).truncate(atOffset: 0); have = 0 }
        if expected > 0, have == expected { return }
        if expected > 0, let free = try? part.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < expected - have + 512_000_000 {
            throw Failure.noSpace(expected - have + 512_000_000 - free)
        }
        written = have
        var r = URLRequest(url: url, timeoutInterval: 60)
        if have > 0 { r.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let t = session.dataTask(with: r)
        task = t
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.addOperation { self.cont = c; t.resume() }
            }
        } onCancel: { t.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            let h = try FileHandle(forWritingTo: part)
            switch code {
            case 206:
                // Content-Range: bytes <inicio>-<fin>/<total>; el inicio tiene que ser lo que ya hay.
                let cr = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
                let start = cr.split(separator: " ").last?.split(separator: "-").first.flatMap { Int64($0) }
                guard start == written else { try? h.close(); throw Failure.badRange(cr.isEmpty ? "sin Content-Range" : cr) }
                try h.seek(toOffset: UInt64(written))
            case 200:
                try h.truncate(atOffset: 0); written = 0
            case 416 where expected > 0 && written == expected:
                try? h.close(); completionHandler(.cancel); finish(nil); return
            case 401, 403, 404, 410:
                try? h.close(); throw Failure.linkExpired(code)
            default:
                try? h.close(); throw Failure.http(code)
            }
            handle = h
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, failure == nil else { return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            if Date().timeIntervalSince(lastReport) > 0.2 { onProgress(written); lastReport = Date() }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize(); try? handle?.close(); handle = nil
        onProgress(written)
        if let failure { finish(failure); return }
        if let e = error as? URLError, e.code == .cancelled { finish(CancellationError()); return }
        if let error { finish(error); return }
        if expected > 0, written != expected {
            finish(Failure.badRange("llegaron \(written) de \(expected) bytes")); return
        }
        finish(nil)
    }

    private func finish(_ error: Error?) {
        guard let c = cont else { return }
        cont = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}

/// SHA-256 de un archivo en bloques de 8 MB, con avance y cancelación.
func sha256(of url: URL, progress: @Sendable (Double) -> Void) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    let total = max(1, RangeDownload.size(url))
    var hasher = SHA256(), done: Int64 = 0, last = Date.distantPast
    while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty {
        try Task.checkCancellation()
        hasher.update(data: chunk)
        done += Int64(chunk.count)
        if Date().timeIntervalSince(last) > 0.2 { progress(Double(done) / Double(total)); last = Date() }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Descargas de la colección: estado por juego, .part reanudables en la carpeta de descargas, índice de lo bajado
/// (downloads.json) y descompresión para construir.
@MainActor @Observable
final class FileboxDownloads {
    enum State: Equatable {
        case downloading(done: Int64, total: Int64, bytesPerSecond: Double)
        case verifying(Double)
        case extracting
        case failed(String)
    }
    struct Entry: Codable, Equatable { var path: String; var updatedAt: String; var extracted: String? }

    static let defaultFolder = GameStaging.root.appendingPathComponent("Descargas").path
    var folder: String { didSet { UserDefaults.standard.set(folder, forKey: "filebox.downloadsDir") } }
    var deleteZipAfterExtract: Bool { didSet { UserDefaults.standard.set(deleteZipAfterExtract, forKey: "filebox.deleteZip") } }
    private(set) var states: [String: State] = [:]
    private(set) var index: [String: Entry] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var speed: [String: (at: Date, bytes: Int64, bps: Double)] = [:]
    private var indexURL: URL { FileboxStore.dir.appendingPathComponent("filebox-downloads.json") }

    init() {
        folder = UserDefaults.standard.string(forKey: "filebox.downloadsDir") ?? Self.defaultFolder
        deleteZipAfterExtract = UserDefaults.standard.object(forKey: "filebox.deleteZip") as? Bool ?? true
        if let d = try? Data(contentsOf: indexURL), let i = try? JSONDecoder().decode([String: Entry].self, from: d) { index = i }
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: FileboxStore.dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(index) { try? d.write(to: indexURL, options: .atomic) }
    }

    func partURL(_ g: FBGame) -> URL {
        URL(fileURLWithPath: folder).appendingPathComponent(Self.safeName(g.file.name) + ".part")
    }
    /// El zip ya descargado y comprobado, si sigue en disco.
    func zip(_ g: FBGame) -> URL? {
        guard let e = index[g.id], FileManager.default.fileExists(atPath: e.path) else { return nil }
        return URL(fileURLWithPath: e.path)
    }
    /// La carpeta descomprimida, si sigue en disco.
    func extracted(_ g: FBGame) -> URL? {
        guard let p = index[g.id]?.extracted, FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }
    /// Bytes de una descarga a medias (pausada o cortada).
    func partial(_ g: FBGame) -> Int64 {
        states[g.id] == nil ? RangeDownload.size(partURL(g)) : 0
    }
    /// La versión de Filebox es más nueva que la descargada.
    func isOutdated(_ g: FBGame) -> Bool {
        guard let e = index[g.id] else { return false }
        return e.updatedAt != g.updatedAt && (zip(g) != nil || extracted(g) != nil)
    }
    var isBusy: Bool { !tasks.isEmpty }

    nonisolated static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "juego" + cleaned : cleaned
    }

    func start(_ g: FBGame, store: FileboxStore) {
        guard tasks[g.id] == nil else { return }
        let id = g.id
        states[id] = .downloading(done: RangeDownload.size(partURL(g)), total: g.file.size, bytesPerSecond: 0)
        speed[id] = nil
        tasks[id] = Task {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                                 reason: "Descargando \(g.title)")
            defer { ProcessInfo.processInfo.endActivity(activity); tasks[id] = nil }
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                let part = partURL(g)
                var game = try await store.fresh(g)
                var retried = false
                while true {
                    guard let url = URL(string: game.file.download.url) else { throw Filebox.Failure.badURL(game.file.download.url) }
                    let total = game.file.size
                    let dl = RangeDownload(url: url, part: part, expected: total) { n in
                        Task { @MainActor in self.progress(id, n, total) }
                    }
                    do { try await dl.run(); break }
                    catch RangeDownload.Failure.linkExpired where !retried {
                        retried = true
                        game = try await store.fresh(game, force: true)
                    }
                }
                states[id] = .verifying(0)
                if let want = game.file.sha256?.lowercased(), !want.isEmpty {
                    let got = try await Task.detached {
                        try sha256(of: part) { f in Task { @MainActor in self.states[id] = .verifying(f) } }
                    }.value
                    guard got == want else {
                        try? FileManager.default.removeItem(at: part)
                        throw Filebox.Failure.http(0, "la descarga no coincide con su SHA-256: se ha borrado, vuelve a descargarla")
                    }
                }
                var dest = URL(fileURLWithPath: folder).appendingPathComponent(Self.safeName(game.file.name))
                if FileManager.default.fileExists(atPath: dest.path) {
                    let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
                    var n = 2
                    repeat { dest = dest.deletingLastPathComponent().appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1 }
                    while FileManager.default.fileExists(atPath: dest.path)
                }
                try FileManager.default.moveItem(at: part, to: dest)
                if let old = index[id], old.path != dest.path { try? FileManager.default.removeItem(atPath: old.path) }
                index[id] = Entry(path: dest.path, updatedAt: game.updatedAt, extracted: index[id]?.extracted)
                saveIndex()
                states[id] = nil
            } catch is CancellationError {
                if states[id] != nil, case .failed = states[id]! {} else { states[id] = nil }
            } catch {
                states[id] = .failed(error.localizedDescription)
            }
        }
    }

    private func progress(_ id: String, _ done: Int64, _ total: Int64) {
        guard case .downloading = states[id] else { return }
        let now = Date()
        var bps = speed[id]?.bps ?? 0
        if let s = speed[id] {
            let dt = now.timeIntervalSince(s.at)
            if dt >= 1 { bps = bps == 0 ? Double(done - s.bytes) / dt : bps * 0.7 + Double(done - s.bytes) / dt * 0.3; speed[id] = (now, done, bps) }
        } else { speed[id] = (now, done, 0) }
        states[id] = .downloading(done: done, total: total, bytesPerSecond: bps)
    }

    /// Espera a que termine la descarga en curso de ese juego (si la hay).
    func wait(_ g: FBGame) async { await tasks[g.id]?.value }

    /// Descargar y dejarlo listo: si es una app de Mac ya construida, se instala en la biblioteca; si son los archivos
    /// del juego, se devuelven para construirlo. nil si la descarga no terminó (pausada, cancelada o fallida).
    func fetchAndOpen(_ g: FBGame, store: FileboxStore, library: GameLibrary) async throws -> Contents? {
        if zip(g) == nil, extracted(g) == nil || isOutdated(g) {
            start(g, store: store)
            await wait(g)
            guard zip(g) != nil else { return nil }
        }
        let c = try await contents(g)
        if case .apps(let folder, let apps) = c {
            library.addFolder(folder.path)
            await library.refresh()
            for a in apps where Quarantine.isSet(a.path) { try? await Quarantine.remove(from: a.path) }
        }
        return c
    }

    /// Pausa: corta la descarga y deja el .part para continuar.
    func pause(_ g: FBGame) { tasks[g.id]?.cancel() }

    /// Cancela y borra lo descargado a medias.
    func discardPartial(_ g: FBGame) {
        tasks[g.id]?.cancel()
        try? FileManager.default.removeItem(at: partURL(g))
        states[g.id] = nil
    }

    func clearError(_ g: FBGame) { if case .failed = states[g.id] { states[g.id] = nil } }

    /// Borra el zip descargado y la carpeta descomprimida (no la app construida).
    func deleteLocal(_ g: FBGame) {
        if let z = zip(g) { try? FileManager.default.removeItem(at: z) }
        if let x = extracted(g) { try? FileManager.default.removeItem(at: x) }
        index[g.id] = nil
        saveIndex()
    }

    /// Lo que trae un juego descargado: archivos para construir, o una app de Mac ya construida (subida desde NX Build).
    enum Contents: Equatable {
        case gameFiles([URL])
        case apps(folder: URL, apps: [URL])
    }

    /// Descomprime el zip en ~/NX Build/<título> (si no estaba ya) y mira qué hay dentro: apps de juego construidas
    /// (se usan tal cual) o NSP/NSZ/XCI/XCZ (para construir). Un descargable que ya sea un NSP se devuelve tal cual.
    func contents(_ g: FBGame) async throws -> Contents {
        if let x = extracted(g), !isOutdated(g) {
            let apps = Self.findApps(in: x)
            if !apps.isEmpty { return .apps(folder: x, apps: apps) }
            let found = Self.findGameFiles(in: x)
            if !found.isEmpty { return .gameFiles(found) }
        }
        guard let z = zip(g) else { throw Filebox.Failure.http(0, "no está descargado") }
        if GameFile.isGameFile(z) { return .gameFiles([z]) }
        let id = g.id
        states[id] = .extracting
        defer { if states[id] == .extracting { states[id] = nil } }
        let dest = GameStaging.root.appendingPathComponent(Self.safeName(g.title))
        try await Task.detached {
            let fm = FileManager.default
            let tmp = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".unzip")
            try? fm.removeItem(at: tmp)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", z.path, tmp.path]
            let err = Pipe(); p.standardError = err
            try p.run()
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                try? fm.removeItem(at: tmp)
                throw Filebox.Failure.http(0, "no se pudo descomprimir: " + msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
        }.value
        index[id]?.extracted = dest.path
        if deleteZipAfterExtract { try? FileManager.default.removeItem(at: z) }
        saveIndex()
        let apps = Self.findApps(in: dest)
        if !apps.isEmpty { return .apps(folder: dest, apps: apps) }
        let found = Self.findGameFiles(in: dest)
        guard !found.isEmpty else {
            throw Filebox.Failure.http(0, "el zip no contiene ningún juego (ni app de Mac ni NSP, NSZ, XCI o XCZ); está en \(dest.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        }
        return .gameFiles(found)
    }

    /// Apps de juego de nxnative hasta 2 niveles por debajo.
    nonisolated static func findApps(in dir: URL) -> [URL] {
        GameLibrary.scan([dir.path], maxDepth: 2).map(\.url)
    }

    /// NSP/NSZ/XCI/XCZ hasta 3 niveles por debajo (sin entrar en apps ni carpetas ocultas o de build).
    nonisolated static func findGameFiles(in dir: URL, depth: Int = 3) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [] {
            if GameFile.isGameFile(item) { out.append(item); continue }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir, depth > 0, item.pathExtension != "app", !item.lastPathComponent.hasSuffix("_build") {
                out += findGameFiles(in: item, depth: depth - 1)
            }
        }
        return out.sorted { $0.path < $1.path }
    }
}

/// Archivos que otra pestaña manda a «Nueva build» (p. ej. un juego recién descargado de Filebox).
@MainActor @Observable
final class BuildInbox {
    var pending: [URL]?
    /// Reconstruir desde la biblioteca: la build de app de Mac empieza sola si todo está listo.
    var autoStart = false
}

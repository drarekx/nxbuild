import Foundation

/// Un archivo de juego (NSP, NSZ, XCI, XCZ) y su papel: juego base, update o DLC.
///
/// El title ID sale como lo saca scripts/build_ipa_from_nsp.py (title_of): primero el nombre del ticket dentro del PFS0
/// (los 16 primeros dígitos del rights ID; la etiqueta del nombre puede estar mal: el NSP base de FFT va etiquetado …0001),
/// luego el `[title ID]` del nombre. La versión, de `[vN]`. Familia (scan_nsps): base …000, update …800,
/// DLC = base + 0x1000 + índice.
struct GameFile: Equatable, Hashable, Sendable {
    enum Role: String, Sendable { case base, update, dlc, unknown }

    var url: URL
    var titleID: UInt64?
    var version: Int?

    var role: Role {
        guard let t = titleID else { return .unknown }
        switch t & 0xFFF {
        case 0: return .base
        case 0x800: return .update
        default: return .dlc
        }
    }

    /// El title ID del juego base de su familia.
    var appID: UInt64? {
        guard let t = titleID else { return nil }
        switch t & 0xFFF {
        case 0: return t
        case 0x800: return t & ~0xFFF
        default: return (t & ~0xFFF) &- 0x1000
        }
    }

    var label: String {
        switch role {
        case .base: "Juego base"
        case .update: "Update" + (version.map { " v\($0)" } ?? "")
        case .dlc: "DLC" + (titleID.map { " " + String(format: "%016llX", $0) } ?? "")
        case .unknown: "Sin title ID"
        }
    }

    static let extensions: Set<String> = ["nsp", "nsz", "xci", "xcz"]

    static func isGameFile(_ u: URL) -> Bool {
        extensions.contains(u.pathExtension.lowercased()) && !u.lastPathComponent.hasPrefix("._")
    }

    static func classify(_ url: URL) -> GameFile {
        var tid = ticketTitleID(url)
        let name = url.lastPathComponent
        if tid == nil, let m = name.firstMatch(of: /\[([0-9A-Fa-f]{16})\]/) { tid = UInt64(m.1, radix: 16) }
        let ver = name.firstMatch(of: /\[v(\d+)\]/).flatMap { Int($0.1) }
        return GameFile(url: url, titleID: tid, version: ver)
    }

    /// El nombre del ticket (<rights ID de 32 hex>.tik) en la tabla PFS0 de un NSP/NSZ.
    static func ticketTitleID(_ url: URL) -> UInt64? {
        guard ["nsp", "nsz"].contains(url.pathExtension.lowercased()),
              let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 0x10), head.count == 0x10, head.prefix(4) == Data("PFS0".utf8) else { return nil }
        let b = [UInt8](head)
        let n = Int(UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24)
        let strSize = Int(UInt32(b[8]) | UInt32(b[9]) << 8 | UInt32(b[10]) << 16 | UInt32(b[11]) << 24)
        guard n > 0, n < 10_000, strSize < 1 << 20, let table = try? h.read(upToCount: n * 0x18 + strSize),
              table.count == n * 0x18 + strSize else { return nil }
        let names = String(decoding: table.suffix(strSize), as: UTF8.self).split(separator: "\0")
        for name in names {
            if let m = name.wholeMatch(of: /([0-9A-Fa-f]{16})[0-9A-Fa-f]{16}\.tik/) { return UInt64(m.1, radix: 16) }
        }
        return nil
    }
}

/// Los archivos elegidos para una build, repartidos por papel. Soltar archivos rellena los huecos: un juego base o
/// los updates soltados sustituyen a los que había; los DLC se añaden.
struct GameSelection: Equatable, Sendable {
    var base: GameFile?
    var updates: [GameFile] = []
    var dlc: [GameFile] = []
    var unknown: [GameFile] = []
    /// Archivos de otro juego, que no entran.
    var ignored: [GameFile] = []

    var files: [GameFile] { (base.map { [$0] } ?? []) + updates + dlc + unknown }
    var isEmpty: Bool { files.isEmpty }
    var appID: UInt64? { base?.appID ?? updates.first?.appID ?? dlc.first?.appID }

    mutating func add(_ new: [GameFile]) {
        ignored = []
        let app = appID ?? new.first(where: { $0.role == .base })?.appID ?? new.compactMap(\.appID).first
        var newUpdates: [GameFile] = []
        for f in new {
            if let a = f.appID, let app, a != app { ignored.append(f); continue }
            switch f.role {
            case .base: base = f
            case .update: newUpdates.append(f)
            case .dlc: if !dlc.contains(where: { $0.url == f.url }) { dlc.append(f) }
            case .unknown: if !unknown.contains(where: { $0.url == f.url }) { unknown.append(f) }
            }
        }
        if !newUpdates.isEmpty { updates = newUpdates }
    }

    mutating func remove(_ f: GameFile) {
        if base?.url == f.url { base = nil }
        updates.removeAll { $0.url == f.url }
        dlc.removeAll { $0.url == f.url }
        unknown.removeAll { $0.url == f.url }
    }

    /// Nombre de la carpeta de trabajo: el del juego base sin etiquetas [..] ni extensión, o el title ID.
    var folderName: String {
        let src = base ?? updates.first ?? dlc.first ?? unknown.first
        guard let src else { return "Juego" }
        var name = src.url.deletingPathExtension().lastPathComponent
        name = name.replacing(/\s*\[[^\]]*\]/, with: "").replacing(/\s*\([^)]*\)\s*$/, with: "")
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || src.role != .base { name = appID.map { String(format: "%016llX", $0) } ?? name }
        return name.isEmpty ? "Juego" : name
    }
}

enum GameStaging {
    static var root: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("NX Build") }

    /// Carpeta fija para un juego con archivos de varias carpetas: un enlace por archivo elegido (el script los sigue y ve
    /// el tamaño y la fecha del original). Siempre la misma carpeta para el mismo juego, así la caché del script vale
    /// entre builds. Solo se tocan enlaces: <id>_build y la app construida quedan.
    static func stage(_ sel: GameSelection, root: URL = root) throws -> URL {
        let dir = root.appendingPathComponent(sel.folderName)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let wanted = Dictionary(sel.files.map { ($0.url.lastPathComponent, $0.url) }, uniquingKeysWith: { a, _ in a })
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
            let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            guard isLink else { continue }
            let target = try? fm.destinationOfSymbolicLink(atPath: item.path)
            if wanted[item.lastPathComponent]?.path != target { try fm.removeItem(at: item) }
        }
        for (name, src) in wanted {
            let link = dir.appendingPathComponent(name)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == src.path { continue }
            try fm.createSymbolicLink(at: link, withDestinationURL: src)
        }
        return dir
    }

    /// ¿Es una carpeta hecha por stage()?
    static func isStaged(_ dir: URL, root: URL = root) -> Bool {
        dir.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path
    }

    /// Los archivos de juego de una carpeta, clasificados (resolviendo los enlaces de una carpeta de stage()).
    static func scan(_ dir: URL) -> GameSelection {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var sel = GameSelection()
        let files = items.filter(GameFile.isGameFile).sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { GameFile.classify($0.resolvingSymlinksInPath()) }
        // En una carpeta los updates se suman (el script usa el más nuevo), no se sustituyen.
        sel.add(files.filter { $0.role != .update })
        let app = sel.appID ?? files.compactMap(\.appID).first
        for f in files where f.role == .update {
            if let app, f.appID != app { sel.ignored.append(f) } else { sel.updates.append(f) }
        }
        return sel
    }
}

/// Reconstruir un juego de la biblioteca: la carpeta de su app, si tiene con qué (los archivos del juego, un NUP o un
/// dump del mismo title ID). La build deja la app nueva en esa misma carpeta, en lugar de la vieja.
enum Rebuild {
    /// Barato (lista la carpeta): para habilitar el menú.
    static func folder(of app: URL) -> URL? {
        let dir = app.deletingLastPathComponent()
        guard let s = GameSource.detect(dir) else { return nil }
        if case .problem = s { return nil }
        return dir
    }

    /// Manda la carpeta del juego a Nueva build para que arranque sola. nil si se ha mandado; si no, por qué no.
    /// Quien llama abre la pantalla de build.
    @MainActor static func request(_ g: LibraryGame, library: GameLibrary, inbox: BuildInbox, runner: BuildRunner) -> String? {
        if runner.isRunning { return "Ya hay una build en marcha." }
        if library.isRunning(g) { return "El juego está abierto. Ciérralo antes de reconstruirlo." }
        if let why = check(app: g.url, titleID: g.titleID) { return why }
        guard let dir = folder(of: g.url) else { return "No están los archivos del juego." }
        inbox.autoStart = true
        inbox.pending = [dir]
        return nil
    }

    /// Antes de empezar: que los archivos sean de ese juego. nil si vale; si no, el motivo.
    static func check(app: URL, titleID: String) -> String? {
        guard let dir = folder(of: app) else {
            return "En «\(app.deletingLastPathComponent().path)» no están los archivos del juego (NSP, NSZ, XCI, .nup o dump)."
        }
        let tid = UInt64(titleID, radix: 16)
        switch GameSource.detect(dir) {
        case .packages?:
            let fams = GameStaging.scan(dir).files.compactMap(\.appID)
            if let tid, !fams.isEmpty, !fams.contains(tid) {
                return "Los archivos de la carpeta son de otro juego (\(fams.map { String(format: "%016llX", $0) }.first ?? "?")), no de \(titleID)."
            }
        case .dump(let t, _, _)?:
            if let t, let tid, t != tid { return "El dump de la carpeta es de otro juego." }
        default: break
        }
        return nil
    }
}

/// De qué está hecho el juego de una carpeta, como lo decide scripts/build_ipa_from_nsp.py: paquetes (NSP/NSZ/XCI/XCZ,
/// necesitan prod.keys), un contenedor NUP (`.nup`, scripts/pack_nup.py) o un dump en carpetas (scripts/pack_dump.py).
/// Los dos últimos no van cifrados: no necesitan prod.keys. Son la forma habitual de los juegos de Switch 2.
enum GameSource: Equatable, Sendable {
    case packages
    case nup(URL)
    case dump(titleID: UInt64?, updates: [Int], dlc: Int)
    /// La carpeta no se puede construir tal cual (p. ej. dos NUP): el motivo.
    case problem(String)

    var needsKeys: Bool { self == .packages }

    var titleID: UInt64? {
        switch self {
        case .nup(let u): u.lastPathComponent.firstMatch(of: /\[([0-9A-Fa-f]{16})\]/).flatMap { UInt64($0.1, radix: 16) }
        case .dump(let t, _, _): t
        default: nil
        }
    }

    /// Los juegos de Switch 2 tienen title ID 04…; los de Switch, 01….
    static func isSwitch2(_ titleID: UInt64?) -> Bool { titleID.map { $0 >> 56 == 0x04 } ?? false }

    static func isNUPFile(_ u: URL) -> Bool {
        guard u.pathExtension.lowercased() == "nup", !u.lastPathComponent.hasPrefix("._"),
              let h = try? FileHandle(forReadingFrom: u) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 3)) == Data("NUP".utf8)
    }

    /// nil: en la carpeta no hay nada que construir.
    static func detect(_ dir: URL) -> GameSource? {
        let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.resolvingSymlinksInPath() }
        if items.contains(where: GameFile.isGameFile) { return .packages }
        let nups = items.filter(isNUPFile)
        if nups.count > 1 {
            return .problem("Hay \(nups.count) NUP en la carpeta (\(nups.map(\.lastPathComponent).joined(separator: ", "))): deja un juego por carpeta.")
        }
        if let n = nups.first { return .nup(n) }
        return dump(dir)
    }

    // MARK: Dump (scripts/pack_dump.py: is_dump, scan)

    private static func isDir(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }
    private static func hasCode(_ u: URL) -> Bool {
        FileManager.default.fileExists(atPath: u.appendingPathComponent("exefs/main.npdm").path)
    }
    private static func isVersion(_ u: URL) -> Bool { hasCode(u) && isDir(u.appendingPathComponent("romfs")) }

    static func dump(_ dir: URL) -> GameSource? {
        let fm = FileManager.default
        let upDir = dir.appendingPathComponent("updates")
        let updates: [Int: URL] = Dictionary(uniqueKeysWithValues: ((try? fm.contentsOfDirectory(at: upDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { isDir($0) && !$0.lastPathComponent.isEmpty && $0.lastPathComponent.allSatisfy(\.isNumber) }
            .compactMap { u in Int(u.lastPathComponent).map { ($0, u) } })
        let base: URL? = hasCode(dir.appendingPathComponent("base")) ? dir.appendingPathComponent("base") : (isVersion(dir) ? dir : nil)
        let isDump = base.map { isDir($0.appendingPathComponent("romfs")) || updates.values.contains { isDir($0.appendingPathComponent("romfs")) } }
            ?? updates.values.contains(where: isVersion)
        guard isDump else { return nil }
        let codeDir = base ?? updates.filter { isVersion($0.value) }.max { $0.key < $1.key }?.value
        let tid = codeDir.flatMap { programID(npdm: $0.appendingPathComponent("exefs/main.npdm")) }
        let dlc = ((try? fm.contentsOfDirectory(at: dir.appendingPathComponent("dlc"), includingPropertiesForKeys: nil)) ?? []).filter(isDir).count
        return .dump(titleID: tid, updates: updates.keys.sorted(), dlc: dlc)
    }

    /// El program ID de la sección ACI0 de main.npdm (pack_dump.program_id).
    static func programID(npdm: URL) -> UInt64? {
        guard let d = try? Data(contentsOf: npdm), d.count >= 0x78, d.prefix(4) == Data("META".utf8) else { return nil }
        let b = [UInt8](d)
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        let off = u32(0x70), size = u32(0x74)
        guard size >= 0x18, off + 0x18 <= b.count, Array(b[off..<off + 4]) == Array("ACI0".utf8) else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[off + 0x10 + $1]) << (8 * $1) }
    }
}

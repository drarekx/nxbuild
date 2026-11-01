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

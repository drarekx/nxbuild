import Foundation

/// Mover un juego a otro disco: la app de Mac, su carpeta de build (<title ID>_build, con la caché de shaders, que tarda
/// horas en rehacerse) y los archivos de los que salió (NSP/NSZ/XCI/XCZ, .nup o el dump), si están en su carpeta.
///
/// - Si la carpeta de la app solo tiene ese juego, se mueve entera: queda `<destino>/<nombre de la carpeta>/`.
///   Si comparte carpeta con otros (p. ej. ~/Applications), solo lo suyo, a `<destino>/<nombre del juego>/`.
/// - Los enlaces que dejó NX Build al soltar archivos sueltos (~/NX Build/<juego>) se sustituyen por el archivo al que
///   apuntan: el NSP original también viaja y la carpeta nueva no depende del disco viejo.
/// - `extract/` y `tmp/` dentro de la carpeta de build no se copian salvo que se pida: son la RomFS extraída (la app ya
///   lleva la suya) y temporales, que la siguiente build vuelve a sacar. Entre discos se borran antes de copiar.
/// - En el mismo disco es un simple renombrado. Entre discos se copia con ditto, se comprueba que la copia tiene los
///   mismos bytes y solo entonces se borra el original. Si algo falla o se cancela, se borra la copia y el original
///   queda como estaba (salvo extract/ y tmp/, que ya se habían borrado).
/// Las partidas no se mueven: están en ~/Library/Application Support/nxnative/<title ID> y van por el title ID.
enum GameMove {
    struct Item: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable { case app, build, survey, game, other }
        var source: URL          // lo que se copia (el destino de un enlace ya resuelto)
        var name: String         // nombre en la carpeta nueva
        var kind: Kind
        var bytes: Int64
        var link: URL?           // el enlace de NX Build que apuntaba a `source`, que se borra al terminar
        var id: String { name }

        var label: String {
            switch kind {
            case .app: "App del juego"
            case .build: "Carpeta de build (caché de shaders)"
            case .survey: "Estudio del juego (survey)"
            case .game: link == nil ? "Archivo del juego" : "Archivo del juego (enlazado)"
            case .other: "Otro"
            }
        }
    }

    struct Plan: Equatable, Sendable {
        var sourceFolder: URL
        var folderName: String
        /// La carpeta de origen solo tiene este juego: se mueve entera y se borra.
        var wholeFolder: Bool
        var items: [Item]
        /// Lo que no viaja y se borra al terminar (extract/ de la build), con su tamaño.
        var dropped: [(url: URL, bytes: Int64)]
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
        var droppedBytes: Int64 { dropped.reduce(0) { $0 + $1.bytes } }

        static func == (a: Plan, b: Plan) -> Bool {
            a.sourceFolder == b.sourceFolder && a.items == b.items && a.dropped.map(\.url) == b.dropped.map(\.url)
        }
    }

    enum Failure: LocalizedError {
        case running, sameFolder, insideSource, noSpace(need: Int64, free: Int64), exists(String), verify(String), failed(String)
        /// Movido y comprobado, pero hay originales que no se pudieron borrar.
        case leftovers(String, [String])
        var errorDescription: String? {
            switch self {
            case .running: "El juego está abierto. Ciérralo antes de moverlo."
            case .sameFolder: "El juego ya está en esa carpeta."
            case .insideSource: "El destino está dentro de la carpeta del juego."
            case .noSpace(let need, let free):
                "No cabe: hacen falta \(fmt(need)) y en ese disco quedan \(fmt(free))."
            case .exists(let p): "Ya existe «\(p)» en el destino."
            case .verify(let what): "La copia de «\(what)» no coincide con el original: no se ha borrado nada del disco de origen."
            case .failed(let why): why
            case .leftovers(let dest, let paths):
                "El juego ya está en «\(dest)» y la copia está comprobada, pero no se pudo borrar del disco viejo: "
                    + paths.joined(separator: ", ") + ". Bórralo a mano si quieres recuperar el espacio."
            }
        }
    }

    static func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    /// Qué se movería. `includeExtract`: copiar también extract/ de la carpeta de build.
    static func plan(app: URL, titleID: String, includeExtract: Bool = false) -> Plan {
        let fm = FileManager.default
        let folder = app.deletingLastPathComponent()
        let tid = UInt64(titleID, radix: 16)
        let entries = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }

        func isLink(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true }
        func target(_ u: URL) -> URL? {
            guard let t = try? fm.destinationOfSymbolicLink(atPath: u.path) else { return nil }
            return URL(fileURLWithPath: t, relativeTo: u.deletingLastPathComponent()).standardizedFileURL
        }
        func isBuildDir(_ n: String) -> Bool { n.lowercased().hasSuffix("_build") }
        func isSurveyDir(_ n: String) -> Bool { n.lowercased().hasSuffix("_survey") }
        func idPrefix(_ n: String) -> UInt64? { n.count >= 16 ? UInt64(n.prefix(16), radix: 16) : nil }
        /// Familia de un archivo de juego (resolviendo enlaces): base, update o DLC del mismo juego.
        func family(_ u: URL) -> UInt64? {
            let real = isLink(u) ? (target(u) ?? u) : u
            if GameFile.isGameFile(real) { return GameFile.classify(real).appID }
            return nil
        }

        // ¿Hay otro juego en la carpeta? Otra app, o archivos/carpetas de build con otro title ID.
        let otherApps = entries.contains { $0.pathExtension == "app" && $0.standardizedFileURL != app.standardizedFileURL }
        let otherGames = entries.contains { u in
            let n = u.lastPathComponent
            if isBuildDir(n) || isSurveyDir(n) { return idPrefix(n).map { $0 != tid } ?? false }
            return family(u).map { $0 != tid } ?? false
        }
        let whole = !otherApps && !otherGames && folder.path != NSHomeDirectory() && folder.path != "/"
            && folder.standardizedFileURL != GameStaging.root.standardizedFileURL

        var items: [Item] = [], dropped: [(URL, Int64)] = []
        for u in entries {
            let n = u.lastPathComponent
            var kind: Item.Kind?
            if u.standardizedFileURL == app.standardizedFileURL { kind = .app }
            else if isBuildDir(n), idPrefix(n) == tid { kind = .build }
            else if isSurveyDir(n), idPrefix(n) == tid { kind = .survey }
            else if family(u) == tid, tid != nil { kind = .game }
            else if whole { kind = (GameFile.isGameFile(u) || GameSource.isNUPFile(isLink(u) ? (target(u) ?? u) : u)) ? .game : .other }
            guard let kind else { continue }
            var src = u, link: URL?
            // Solo los enlaces a archivos de juego (los que deja NX Build) se cambian por el archivo; cualquier otro enlace
            // viaja como enlace, sin arrastrar lo que apunta.
            if isLink(u), kind == .game {
                guard let t = target(u), fm.fileExists(atPath: t.path) else { continue }   // enlace roto: no hay nada que mover
                src = t; link = u
            }
            var bytes = isLink(src) ? 0 : FreeSpace.size(of: src)
            if kind == .build, !includeExtract {
                for sub in ["extract", "tmp"] {
                    let d = src.appendingPathComponent(sub)
                    if fm.fileExists(atPath: d.path) { let b = FreeSpace.size(of: d); dropped.append((d, b)); bytes -= b }
                }
            }
            items.append(Item(source: src, name: n, kind: kind, bytes: max(0, bytes), link: link))
        }
        let order: [Item.Kind] = [.app, .game, .build, .survey, .other]
        items.sort { (order.firstIndex(of: $0.kind)!, $0.name) < (order.firstIndex(of: $1.kind)!, $1.name) }
        let name = whole ? folder.lastPathComponent : app.deletingPathExtension().lastPathComponent
        return Plan(sourceFolder: folder, folderName: name, wholeFolder: whole, items: items, dropped: dropped)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func vol(_ u: URL) -> NSObject? {
            var p = u
            while !FileManager.default.fileExists(atPath: p.path), p.path != "/" { p.deleteLastPathComponent() }
            return (try? p.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let x = vol(a), let y = vol(b) else { return false }
        return x.isEqual(y)
    }

    /// El formato del disco (APFS, Mac OS Plus, ExFAT…) y si un juego de Mac funciona bien en él.
    static func volumeFormat(_ u: URL) -> (name: String, ok: Bool) {
        let name = (try? u.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]))?.volumeLocalizedFormatDescription ?? "?"
        let low = name.lowercased()
        return (name, !(low.contains("exfat") || low.contains("ms-dos") || low.contains("fat") || low.contains("ntfs")))
    }

    /// Bytes de los archivos (tamaño lógico, no el que ocupan en disco: cambia de un formato a otro), sin seguir enlaces.
    static func logicalBytes(_ u: URL) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Int64((try? u.resourceValues(forKeys: keys))?.fileSize ?? 0) }
        var total: Int64 = 0
        let e = fm.enumerator(at: u, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil)
        while let f = e?.nextObject() as? URL {
            if f.lastPathComponent.hasPrefix("._") { continue }   // AppleDouble que crea un disco exFAT
            if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    /// Mueve el plan a `destRoot/<folderName>`. Devuelve la carpeta nueva.
    /// `forceCopy`: copiar y borrar aunque sea el mismo disco (para los tests).
    static func run(_ plan: Plan, to destRoot: URL, forceCopy: Bool = false, report: @escaping Quarantine.Report) async throws -> URL {
        let fm = FileManager.default
        let dest = destRoot.appendingPathComponent(plan.folderName)
        if dest.standardizedFileURL == plan.sourceFolder.standardizedFileURL { throw Failure.sameFolder }
        if dest.standardizedFileURL.path.hasPrefix(plan.sourceFolder.standardizedFileURL.path + "/") { throw Failure.insideSource }
        for it in plan.items where fm.fileExists(atPath: dest.appendingPathComponent(it.name).path) {
            throw Failure.exists(dest.appendingPathComponent(it.name).path)
        }
        let local = !forceCopy && sameVolume(plan.sourceFolder, destRoot) && plan.items.allSatisfy { sameVolume($0.source, destRoot) }
        if !local, let free = FreeSpace.freeBytes(on: destRoot), free < plan.bytes + (1 << 30) {
            throw Failure.noSpace(need: plan.bytes, free: free)
        }
        let createdDest = !fm.fileExists(atPath: dest.path)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var done: [URL] = []

        // Entre discos, lo que no viaja (extract/ y tmp/ de la build, que la siguiente build rehace) se borra antes de
        // copiar. En el mismo disco no cuesta nada y se queda.
        if !local { for d in plan.dropped { try? remove(d.url) } }

        do {
            if local {
                for (i, it) in plan.items.enumerated() {
                    try Task.checkCancellation()
                    report(.init(step: "Moviendo", done: i, total: plan.items.count, current: it.name))
                    try fm.moveItem(at: it.source, to: dest.appendingPathComponent(it.name))
                    done.append(dest.appendingPathComponent(it.name))
                }
            } else {
                let total = plan.bytes
                var before: Int64 = 0
                for it in plan.items {
                    try Task.checkCancellation()
                    let to = dest.appendingPathComponent(it.name)
                    let step = "Copiando a " + destRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    try copy(it.source, to: to) { copied in
                        report(.init(step: step, done: Int((before + copied) >> 20), total: Int(max(total, 1) >> 20),
                                     current: it.name, unit: .megabytes))
                    }
                    done.append(to)
                    report(.init(step: "Comprobando la copia", done: Int(before >> 20), total: Int(max(total, 1) >> 20),
                                 current: it.name, unit: .megabytes))
                    let a = logicalBytes(it.source), b = logicalBytes(to)
                    guard a == b else { throw Failure.verify(it.name) }
                    before += it.bytes
                }
            }
        } catch {
            for u in done.reversed() where !local { try? remove(u) }
            if local {   // devolver lo ya movido a su sitio
                for it in plan.items {
                    let moved = dest.appendingPathComponent(it.name)
                    if fm.fileExists(atPath: moved.path), !fm.fileExists(atPath: it.source.path) { try? fm.moveItem(at: moved, to: it.source) }
                }
            }
            if createdDest { try? fm.removeItem(at: dest) }
            throw error is CancellationError ? Quarantine.Failure.cancelled : error
        }
        // Todo copiado y comprobado: ahora sí, fuera los originales. Desde aquí ya no se deshace nada (la copia es buena):
        // lo que no se pueda borrar se dice, y se queda duplicado.
        var leftovers: [String] = []
        if !local {
            report(.init(step: "Borrando el original", current: plan.sourceFolder.lastPathComponent))
            for it in plan.items {
                do { try remove(it.source) } catch { leftovers.append(it.source.path) }
            }
        }
        for it in plan.items { if let l = it.link { try? fm.removeItem(at: l) } }
        if plan.wholeFolder {
            // La carpeta vieja ya solo tiene restos (.DS_Store): fuera.
            let rest = ((try? fm.contentsOfDirectory(atPath: plan.sourceFolder.path)) ?? []).filter { $0 != ".DS_Store" && !$0.hasPrefix("._") }
            if rest.isEmpty { try? fm.removeItem(at: plan.sourceFolder) }
        }
        if !leftovers.isEmpty { throw Failure.leftovers(dest.path, leftovers) }
        return dest
    }

    /// ditto copia el bundle con sus atributos y firma; el progreso se mide por lo que ya hay en el destino.
    private static func copy(_ src: URL, to: URL, progress: @escaping (Int64) -> Void) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = [src.path, to.path]
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("nxbuild-ditto-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errFile) }
        p.standardError = try FileHandle(forWritingTo: errFile)
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        while p.isRunning {
            if Task.isCancelled { p.terminate() }
            progress(logicalBytes(to))
            Thread.sleep(forTimeInterval: 1)
        }
        p.waitUntilExit()
        if Task.isCancelled { throw CancellationError() }
        guard p.terminationStatus == 0 else {
            let err = ((try? String(contentsOf: errFile, encoding: .utf8)) ?? "").split(separator: "\n").prefix(3).joined(separator: "\n")
            throw Failure.failed("No se pudo copiar «\(src.lastPathComponent)»: " + (err.isEmpty ? "ditto terminó con \(p.terminationStatus)" : err))
        }
    }

    /// Borra, quitando antes la protección de escritura que llevan algunos archivos de las apps.
    private static func remove(_ u: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: u.path) || (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil else { return }
        if (try? fm.removeItem(at: u)) != nil { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["-R", "u+w", u.path]
        try? p.run(); p.waitUntilExit()
        try fm.removeItem(at: u)
    }
}

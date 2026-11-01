import Foundation

/// Lo que la siguiente build vuelve a hacer dentro de la carpeta de build de un juego (<title ID>_build, o la de
/// --work-dir). Disposición de scripts/build_ipa_from_nsp.py. Se queda lo que el script guarda por algo:
/// logs/, profile/ (un perfil provisional o derivado, que alguien puede haber editado), run/ (la partida de la build de
/// desarrollo para Mac) y nsp/ (NSZ ya convertidos a NSP: son archivos del juego).
enum FreeSpace {
    struct Group: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
        var paths: [URL]
        var bytes: Int64
    }

    /// Grupos borrables, en orden. Los nombres son relativos a la carpeta de build; patched_* va con su .key.
    static let layout: [(id: String, title: String, detail: String, names: [String], prefixes: [String])] = [
        ("extract", "Archivos extraídos", "extract/ y aoc/: el juego desempaquetado. Volver a extraer tarda unos minutos.",
         ["extract", "aoc"], []),
        ("shader", "Shaders y cachés", "shader/ y pso/: la siguiente build los recompila (puede tardar bastante).",
         ["shader", "pso"], []),
        ("package", "Paquete y proyecto de Xcode", "ipa/, app/, xcode/, xcode-derived-data/ y tmp/.",
         ["ipa", "app", "xcode", "xcode-derived-data", "tmp"], []),
        ("code", "Código reescrito y herramientas", "patched_*/, tools/ y font/.",
         ["tools", "font"], ["patched_"]),
    ]

    /// Lo que nunca se borra.
    static let kept: Set<String> = ["logs", "profile", "run", "nsp"]

    /// ¿Es una carpeta de build del script? Por el nombre y por tener alguna de sus carpetas.
    static func isBuildDir(_ dir: URL) -> Bool {
        let name = dir.lastPathComponent
        guard name.hasSuffix("_build") || name == "build" else { return false }
        let known = ["logs", "extract", "shader", "profile", "tools"]
        return known.contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// Las carpetas de build de un juego: <carpeta>/<title ID>_build y la de ~/NX Build cuando se construyó fuera de la nube.
    static func buildDirs(for nspDir: URL, extra: [URL] = []) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: nspDir, includingPropertiesForKeys: nil)) ?? []
        func norm(_ u: URL) -> URL { URL(fileURLWithPath: u.resolvingSymlinksInPath().path) }
        var out = items.filter(isBuildDir).map(norm)
        for e in (extra + [CloudFolder.localWorkDir(for: nspDir)]).map(norm) where isBuildDir(e) && !out.contains(e) { out.append(e) }
        return out.sorted { $0.path < $1.path }
    }

    static func groups(in buildDir: URL) -> [Group] {
        let items = (try? FileManager.default.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: nil)) ?? []
        return layout.compactMap { g in
            let paths = items.filter { u in
                let n = u.lastPathComponent
                return !kept.contains(n) && (g.names.contains(n) || g.prefixes.contains { n.hasPrefix($0) })
            }
            guard !paths.isEmpty else { return nil }
            return Group(id: g.id, title: g.title, detail: g.detail, paths: paths.sorted { $0.path < $1.path },
                         bytes: paths.reduce(0) { $0 + size(of: $1) })
        }
    }

    /// Espacio ocupado en disco (sin seguir enlaces).
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Int64((try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil)
        while let f = e?.nextObject() as? URL {
            if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true { total += Int64(v.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static func freeBytes(on url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Borra los grupos y devuelve cuánto espacio libre ganó el disco (puede ser menos que su tamaño: la app de Mac
    /// guarda el RomFS como clones APFS de extract/, que siguen ocupando mientras exista la app).
    static func delete(_ groups: [Group], in buildDir: URL) throws -> Int64? {
        let before = freeBytes(on: buildDir)
        let base = buildDir.standardizedFileURL.path + "/"
        for g in groups {
            for p in g.paths {
                // Solo hijos directos de la carpeta de build, nunca lo que se conserva.
                guard p.standardizedFileURL.path.hasPrefix(base), p.deletingLastPathComponent().standardizedFileURL == buildDir.standardizedFileURL,
                      !kept.contains(p.lastPathComponent) else { continue }
                try FileManager.default.removeItem(at: p)
                if p.lastPathComponent.hasPrefix("patched_") && !p.lastPathComponent.hasSuffix(".key") {
                    try? FileManager.default.removeItem(at: p.appendingPathExtension("key"))
                }
            }
        }
        guard let before, let after = freeBytes(on: buildDir) else { return nil }
        return after - before
    }
}

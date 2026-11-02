import Foundation

/// Qué juego de la biblioteca es qué juego de Filebox: por title ID; si la ficha de Filebox no lo trae, el que va en el
/// nombre del zip («Juego [0100…] (Mac).zip», como sube NX Build) y, para fichas antiguas sin ninguno, por nombre.
extension FBGame {
    /// Title ID de la ficha o, si no tiene, el que va entre corchetes en el nombre del archivo o en el título.
    var resolvedTitleID: String? {
        if let t = titleId?.uppercased(), GameMatch.isTitleID(t) { return t }
        return GameMatch.titleID(in: file.name) ?? GameMatch.titleID(in: title)
    }

    /// Título sin « (Mac)» ni « [title ID]», para mostrarlo.
    var displayTitle: String { GameMatch.cleanTitle(title) }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

enum GameMatch {
    static func isTitleID(_ s: String) -> Bool {
        s.count == 16 && s.allSatisfy(\.isHexDigit)
    }

    /// «[0100F2C0115B6000]» en cualquier parte del texto.
    static func titleID(in s: String) -> String? {
        guard let r = s.range(of: #"\[[0-9A-Fa-f]{16}\]"#, options: .regularExpression) else { return nil }
        return String(s[r].dropFirst().dropLast()).uppercased()
    }

    static func cleanTitle(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s*\[[0-9A-Fa-f]{16}\]"#, with: "", options: .regularExpression)
        if t.hasSuffix(" (Mac)") { t.removeLast(6) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Clave para comparar nombres: sin mayúsculas, acentos ni signos («Pokémon Legends: Arceus» = «Pokemon Legends_ Arceus»).
    static func nameKey(_ s: String) -> String {
        cleanTitle(s).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func matches(_ lib: LibraryGame, _ fb: FBGame) -> Bool {
        if let t = fb.resolvedTitleID { return !lib.titleID.isEmpty && t == lib.titleID.uppercased() }
        let k = nameKey(fb.title)
        return !k.isEmpty && k == nameKey(lib.name)
    }

    /// Lo que hay en Filebox de un juego de la biblioteca.
    struct Presence: Equatable {
        var macBuild: FBGame?       // la app ya construida, subida desde NX Build
        var sources: FBGame?        // los archivos del juego (NSP/XCI…) para construirlo

        var isEmpty: Bool { macBuild == nil && sources == nil }
        var summary: String {
            switch (macBuild != nil, sources != nil) {
            case (true, true): "app de Mac y archivos del juego"
            case (true, false): "app de Mac subida"
            case (false, true): "solo los archivos del juego"
            case (false, false): "no está"
            }
        }
    }

    static func presence(of lib: LibraryGame, in games: [FBGame]) -> Presence {
        var p = Presence()
        for g in games where matches(lib, g) {
            if g.isMacBuild { if p.macBuild == nil { p.macBuild = g } } else if p.sources == nil { p.sources = g }
        }
        return p
    }

    static func inLibrary(_ fb: FBGame, _ library: [LibraryGame]) -> LibraryGame? {
        library.first { matches($0, fb) }
    }
}

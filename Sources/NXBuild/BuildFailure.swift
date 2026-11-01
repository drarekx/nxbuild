import Foundation

/// Por qué ha parado una build y qué hacer, a partir del log.
///
/// El script escribe en pantalla una línea `[RED] …` por cada parada (un BuildError) y deja la salida de cada herramienta
/// solo en `<id>_build/logs/`, citada como «(full output: <ruta>)» o «(list: <ruta>)». En un NSP dañado la línea en pantalla
/// es solo «nx_extract exit code 3»: el motivo está en ese archivo. Por eso se lee también el final de cada log citado.
struct BuildFailure: Equatable {
    enum Kind: String {
        case driveMissing, rosetta, pythonModules, translator, tools, iosSDK, cltSelected, metalMissing
        case otherMetal, shaderRegression, damagedNSP, a32Program
        case keysMissing, keysOld, severalGames, noGame, updateMissing, diskFull, cloudFolder
        case unsupportedShaders, language, unknown
    }

    enum Action: Equatable {
        case openDependencies
        case openSettings
        case retry(flag: String)   // vuelve a construir con un --allow-*
    }

    var kind: Kind
    var title: String
    var next: String
    var actions: [Action] = []
    /// La línea del log que lo explica (o la última [RED]), para mostrarla tal cual.
    var evidence: String?
    /// El archivo de log citado por el error, para abrirlo.
    var logFile: URL?
}

enum BuildFailureClassifier {
    /// Un patrón (expresión regular) por mensaje de scripts/build_ipa_from_nsp.py, dm/tools/nx_extract/Program.cs,
    /// dm/gfx/tools/own_compilers.py o dm/tools/nso.py. El primero que aparece en el texto gana.
    static let table: [(kind: BuildFailure.Kind, pattern: String)] = [
        (.rosetta, "is an Intel one running under Rosetta"),
        (.translator, "the shader translator does not (run|start)"),
        (.pythonModules, "is missing modules: |Capstone [0-9.]+ is unsupported|need the zbic package|NSZ / XCZ files need the nsz tool|Direct RomFS image builds require Python 3\\.12"),
        (.iosSDK, "the iOS SDK is not installed"),
        (.cltSelected, "the selected developer folder is the Command Line Tools"),
        (.metalMissing, "the Metal compiler does not run"),
        (.tools, "tools not found: |spirv-cross is missing|dotnet not found|glslangValidator not found|the shader translator is missing"),
        (.otherMetal, "Metal compiler is not the one the shaders were tested with"),
        (.shaderRegression, "a change to the translation chain broke them"),
        (.damagedNSP, "files fail the NCA's hash check|hash check failed: "),
        (.a32Program, "is a 32-bit ARM program"),
        (.keysMissing, "(?m)^\\[RED\\] no such file: "),
        (.keysOld, "MissingKeyException|[Mm]issing (title |key area |header )?key|Unable to decrypt"),
        (.severalGames, "more than one game in the folder"),
        (.noGame, "no NSP with a readable title ID in |no base game NSP found in |not a folder: "),
        (.updateMissing, "no NSP for update "),
        (.diskFull, "less than [0-9]+ GB free on the volume of |No space left on device"),
        (.cloudFolder, "resource fork, Finder information, or similar detritus not allowed"),
        (.unsupportedShaders, "the shader split found no shaders|Unreal paks, but none"),
        (.language, "the game has no .+; its languages: |unknown game language"),
    ]

    struct Inputs {
        var nspDir = ""
        var keysPath = ""
        var volumes = "/Volumes"
    }

    /// `log`: las líneas de la ventana. Lee además el final de cada log que citen.
    static func classify(log: [String], inputs: Inputs) -> BuildFailure {
        let files = citedLogs(in: log)
        var text = log.joined(separator: "\n")
        for f in files { text += "\n" + tail(of: f) }
        let logFile = files.last

        // Un disco desconectado explica todo lo demás («not a folder», un enlace roto…).
        for path in [inputs.nspDir, inputs.keysPath] where !path.isEmpty {
            if let vol = unmountedVolume(path, volumes: inputs.volumes) {
                return make(.driveMissing, detail: vol, evidence: nil, logFile: logFile)
            }
        }
        for row in table {
            guard let r = text.range(of: row.pattern, options: .regularExpression) else { continue }
            return make(row.kind, detail: detail(row.kind, in: text), evidence: lineAround(r, in: text), logFile: logFile)
        }
        if !inputs.keysPath.isEmpty, !FileManager.default.isReadableFile(atPath: inputs.keysPath) {
            return make(.keysMissing, detail: nil, evidence: nil, logFile: logFile)
        }
        let lastRed = log.last { $0.hasPrefix("[RED] ") }.map { String($0.dropFirst(6)) }
        return make(.unknown, detail: nil, evidence: lastRed, logFile: logFile)
    }

    // MARK: - Textos

    private static func make(_ kind: BuildFailure.Kind, detail: String?, evidence: String?, logFile: URL?) -> BuildFailure {
        let (title, next, actions): (String, String, [BuildFailure.Action]) = switch kind {
        case .driveMissing:
            ("Disco desconectado", "«\(detail ?? "?")» no está montado. Conéctalo (¿NAS?) y vuelve a construir.", [])
        case .rosetta:
            ("Python de Intel (Rosetta)", "Las herramientas correrían como Intel y no encontrarían .NET. Usa un Python arm64: en Dependencias, «Crear venv local».", [.openDependencies])
        case .pythonModules:
            ("Faltan módulos de Python", "Instálalos desde Dependencias (Módulos Python).", [.openDependencies])
        case .translator:
            ("El traductor de shaders no arranca", "Necesita el runtime de .NET 10 para arm64. Instálalo desde Dependencias; si tienes DOTNET_ROOT apuntando a otro .NET, quítalo.", [.openDependencies])
        case .tools:
            ("Faltan herramientas", "Instálalas desde Dependencias.", [.openDependencies])
        case .iosSDK:
            ("Falta la plataforma iOS de Xcode", "Instálala desde Dependencias, o elige «App para Mac».", [.openDependencies])
        case .cltSelected:
            ("Xcode no está seleccionado", "Están seleccionadas las Command Line Tools. En Dependencias, «Seleccionar Xcode».", [.openDependencies])
        case .metalMissing:
            ("El compilador Metal no arranca", "Instala el Metal Toolchain desde Dependencias.", [.openDependencies])
        case .otherMetal:
            ("Compilador Metal distinto del probado", "Los shaders pueden salir mal (issue #242). Usa el Xcode del lock, o construye igualmente.", [.retry(flag: "--allow-other-metal")])
        case .shaderRegression:
            ("Shaders que antes funcionaban ahora fallan", "Un cambio del traductor los rompió (lista en logs/shader_regressions.log). Puedes construir sin ellos.", [.retry(flag: "--allow-shader-regressions")])
        case .damagedNSP:
            ("NSP dañado", "Hay archivos que no pasan la comprobación de hash: copia incompleta o descarga rota. Vuelve a copiarlo, o construye igualmente con los archivos tal cual.", [.retry(flag: "--allow-damaged")])
        case .a32Program:
            ("Juego de 32 bits", "Es un programa ARM de 32 bits: nxnative solo convierte juegos de 64 bits. No se puede construir.", [])
        case .keysMissing:
            ("No encuentro prod.keys", "Elige el archivo prod.keys otra vez.", [])
        case .keysOld:
            ("prod.keys no abren el juego", "Faltan claves de la generación que pide el juego o el update. Saca unas prod.keys de una consola con un firmware más reciente.", [])
        case .severalGames:
            ("Varios juegos en la carpeta", "Deja un juego por carpeta, o indica cuál con --title-id en Argumentos extra.", [])
        case .noGame:
            ("No hay juego en la carpeta", "La carpeta no tiene un NSP/NSZ/XCI con title ID legible del juego base. Revisa que sea la carpeta correcta.", [])
        case .updateMissing:
            ("Falta el update que pide el perfil", "El perfil del juego necesita una versión de update que no está en la carpeta. Añade ese NSP (GAMES.md dice cuál).", [])
        case .diskFull:
            ("Sin espacio en disco", detail.map { "Hacen falta al menos \($0) GB libres en el disco de la build. Libera espacio y vuelve a construir." }
                ?? "El disco se ha llenado. Libera espacio y vuelve a construir.", [])
        case .cloudFolder:
            ("Carpeta sincronizada con la nube", "codesign rechaza los atributos que añade iCloud/Dropbox/OneDrive. Activa «Construir en ~/NX Build» bajo la carpeta del juego, o mueve el juego a una carpeta que no se sincronice.", [])
        case .unsupportedShaders:
            ("Juego sin soporte de shaders", "El juego guarda los shaders en un formato que el split aún no lee: hace falta trabajo en nxnative (docs/agents).", [])
        case .language:
            ("Idioma no disponible", "El juego no tiene ese idioma. Cambia o borra el idioma en Opciones avanzadas.", [])
        case .unknown:
            ("La build ha fallado", "No reconozco el error. Mira la última línea roja y el log.", [])
        }
        return BuildFailure(kind: kind, title: title, next: next, actions: actions, evidence: evidence, logFile: logFile)
    }

    // MARK: - Utilidades

    /// Rutas citadas como «(full output: X)», «(list: X)» o «(see X)», que existan.
    static func citedLogs(in lines: [String]) -> [URL] {
        var out: [URL] = []
        let re = /\((?:full output|list|host output): ([^)]+)\)|\(see ([^)\s]+)/
        for line in lines {
            for m in line.matches(of: re) {
                let p = String(m.output.1 ?? m.output.2 ?? "").trimmingCharacters(in: .whitespaces)
                let u = URL(fileURLWithPath: p)
                if !p.isEmpty, FileManager.default.fileExists(atPath: p), !out.contains(u) { out.append(u) }
            }
        }
        return out
    }

    /// Los últimos 64 KB de un archivo.
    static func tail(of url: URL, bytes: Int = 65_536) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    }

    /// El disco de /Volumes/<nombre> que no está montado, o nil.
    static func unmountedVolume(_ path: String, volumes: String) -> String? {
        let prefix = volumes.hasSuffix("/") ? volumes : volumes + "/"
        guard path.hasPrefix(prefix), let name = path.dropFirst(prefix.count).split(separator: "/").first else { return nil }
        return FileManager.default.fileExists(atPath: prefix + name) ? nil : String(name)
    }

    private static func detail(_ kind: BuildFailure.Kind, in text: String) -> String? {
        guard kind == .diskFull, let r = text.range(of: "less than [0-9]+ GB", options: .regularExpression) else { return nil }
        return text[r].split(separator: " ").dropFirst(2).first.map(String.init)
    }

    /// La línea entera donde está la coincidencia, sin el prefijo [RED].
    private static func lineAround(_ r: Range<String.Index>, in text: String) -> String {
        let start = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let end = text[r.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        var line = String(text[start..<end])
        if line.hasPrefix("[RED] ") { line.removeFirst(6) }
        return line.count > 400 ? String(line.prefix(400)) + "…" : line
    }
}

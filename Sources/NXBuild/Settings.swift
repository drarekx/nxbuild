import Foundation
import Observation

/// Rutas que el .command tenía fijas; editables en Ajustes y guardadas en UserDefaults.
@MainActor @Observable
final class AppSettings {
    private let d = UserDefaults.standard
    static let defaultRoot = NSHomeDirectory() + "/dev/switch"

    var pythonPath: String { didSet { d.set(pythonPath, forKey: "pythonPath") } }
    var repoPath: String { didSet { d.set(repoPath, forKey: "repoPath") } }
    var keysPath: String { didSet { d.set(keysPath, forKey: "keysPath") } }
    var lastNSPDir: String { didSet { d.set(lastNSPDir, forKey: "lastNSPDir") } }
    var defaultBrowseDir: String { didSet { d.set(defaultBrowseDir, forKey: "defaultBrowseDir") } }
    var notifyOnFinish: Bool { didSet { d.set(notifyOnFinish, forKey: "notifyOnFinish") } }
    /// Jugar sin la ventana de ajustes del propio juego (DM_LAUNCHER=0): las opciones se eligen en NX Build.
    var skipGameWindow: Bool { didSet { d.set(skipGameWindow, forKey: "skipGameWindow") } }

    init() {
        pythonPath = d.string(forKey: "pythonPath") ?? "/Volumes/Download/nxnative-venv/bin/python3"
        repoPath = d.string(forKey: "repoPath") ?? Self.defaultRoot + "/nxnative"
        keysPath = d.string(forKey: "keysPath") ?? Self.defaultRoot + "/prod/prod.keys"
        lastNSPDir = d.string(forKey: "lastNSPDir") ?? ""
        defaultBrowseDir = d.string(forKey: "defaultBrowseDir") ?? "/Volumes/Download"
        notifyOnFinish = d.object(forKey: "notifyOnFinish") as? Bool ?? true
        skipGameWindow = d.object(forKey: "skipGameWindow") as? Bool ?? true
    }

    var pythonOK: Bool { FileManager.default.isExecutableFile(atPath: pythonPath) }
    var scriptOK: Bool { FileManager.default.fileExists(atPath: repoPath + "/scripts/build_ipa_from_nsp.py") }
}

/// Opciones extra de build_ipa_from_nsp.py que la app expone.
struct BuildOptions {
    var language = ""
    var romfsSeparate = false
    var showFPS = true
    var motion = true
    var allowDamaged = false
    var allowOtherMetal = false
    var allowShaderRegressions = false
    var keepExtracted = true
    var appName = ""
    var extraArgs = ""
    /// --work-dir: carpeta de build fuera de la nube (vacío = <title ID>_build en la carpeta del juego).
    var workDir = ""

    func arguments(platform: Platform) -> [String] {
        var a: [String] = []
        let lang = language.trimmingCharacters(in: .whitespaces)
        if !lang.isEmpty { a += ["-l", lang] }
        let name = appName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { a += ["--app-name", name] }
        if platform == .ios {
            if romfsSeparate { a += ["--romfs", "separate"] }
            if !showFPS { a.append("--no-show-fps") }
        }
        if !motion { a.append("--no-motion") }
        if !keepExtracted { a.append("--no-keep-extracted") }
        if allowDamaged { a.append("--allow-damaged") }
        if allowOtherMetal { a.append("--allow-other-metal") }
        if allowShaderRegressions { a.append("--allow-shader-regressions") }
        if !workDir.isEmpty { a += ["--work-dir", workDir] }
        a += splitArgs(extraArgs)
        return a
    }
}

/// Partición simple estilo shell: espacios separan, comillas simples/dobles agrupan.
func splitArgs(_ s: String) -> [String] {
    var out: [String] = [], cur = "", quote: Character? = nil, has = false
    for c in s {
        if let q = quote {
            if c == q { quote = nil } else { cur.append(c) }
        } else if c == "'" || c == "\"" {
            quote = c; has = true
        } else if c.isWhitespace {
            if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
        } else { cur.append(c) }
    }
    if has || !cur.isEmpty { out.append(cur) }
    return out
}

/// Compara el compilador Metal de este Mac con el que fija dm/gfx/tools/dmsh_chain.lock.
struct MetalCheck: Sendable {
    var local: String?
    var locked: String?
    var matches: Bool { local != nil && local == locked }

    static func run(repoPath: String) async -> MetalCheck {
        await Task.detached {
            let lockFile = repoPath + "/dm/gfx/tools/dmsh_chain.lock"
            var locked: String?
            if let txt = try? String(contentsOfFile: lockFile, encoding: .utf8) {
                for line in txt.split(separator: "\n") where line.hasPrefix("metal_macosx\t") {
                    locked = String(line.dropFirst("metal_macosx\t".count))
                }
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["-sdk", "macosx", "metal", "--version"]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            var local: String?
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                local = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
            }
            return MetalCheck(local: local, locked: locked)
        }.value
    }
}

import Foundation
import AppKit

/// «Copiar diagnóstico»: un informe corto en Markdown para pegar en una issue. En inglés, para quien lo lea upstream.
///
/// Privado por construcción: la carpeta de usuario sale como ~, una línea con pinta de clave (`nombre = <hex>`, la forma de
/// prod.keys y title.keys) se queda solo con el nombre, cualquier secuencia hex de 32 o más caracteres se tapa, y no se
/// incluye nada del entorno.
enum Diagnostics {
    struct Input: Sendable {
        var repoPath: String
        var pythonPath: String
        var deps: [(name: String, state: String, detail: String)]
        var game: String?
        var gameFiles: [String]
        var keyCheck: String?
        var platform: String
        var phase: String
        var failure: String?
        var command: String?
        var logTail: [String]
    }

    static func report(_ i: Input) -> String {
        var r: [String] = ["## NX Build diagnostics", ""]

        let info = ProcessInfo.processInfo
        let appVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        r += ["### System",
              "- NX Build: \(appVer)",
              "- macOS: \(info.operatingSystemVersionString)",
              "- Chip: \(sh("sysctl -n machdep.cpu.brand_string").first ?? "?"), RAM \(info.physicalMemory / 1_073_741_824) GB",
              ""]

        let git = "git -C \(q(i.repoPath))"
        let head = sh("\(git) log -1 --format='%h %cd' --date=short").first
        let branch = sh("\(git) rev-parse --abbrev-ref HEAD").first
        let dirty = sh("\(git) status --porcelain --untracked-files=no").count
        func behind(_ ref: String) -> String {
            guard let n = sh("\(git) rev-list --count HEAD..\(ref) 2>/dev/null").first else { return "n/a" }
            return "\(n) behind"
        }
        r += ["### Repository (\(i.repoPath))",
              "- Commit: \(head ?? "not a git checkout")" + (branch.map { " on \($0)" } ?? ""),
              "- Uncommitted tracked changes: \(dirty)",
              "- origin/main: \(behind("origin/main")), upstream/main: \(behind("upstream/main")) (as of the last fetch; nothing fetched)",
              ""]

        let lockPath = i.repoPath + "/dm/gfx/tools/dmsh_chain.lock"
        let lock = (try? String(contentsOfFile: lockPath, encoding: .utf8)) ?? ""
        func locked(_ key: String) -> String {
            lock.split(separator: "\n").first { $0.hasPrefix(key + "\t") }.map { String($0.dropFirst(key.count + 1)) } ?? "?"
        }
        r += ["### Toolchain",
              "- Python: \(i.pythonPath) → \(sh("\(q(i.pythonPath)) -c 'import sys,platform; print(sys.version.split()[0], platform.machine(), \"venv\" if sys.prefix != sys.base_prefix else \"system\")'").first ?? "does not run")",
              "- .NET SDKs: \(sh("dotnet --list-sdks").map { $0.components(separatedBy: " [").first ?? $0 }.joined(separator: ", ").ifEmpty("none"))",
              "- Xcode: \(sh("xcodebuild -version").first ?? "?") at \(sh("xcode-select -p").first ?? "?")",
              "- Metal macOS: \(sh("xcrun -sdk macosx metal --version").first ?? "?") (lock: \(locked("metal_macosx")))",
              "- Metal iOS: \(sh("xcrun -sdk iphoneos metal --version").first ?? "?") (lock: \(locked("metal_iphoneos")))",
              "- iOS SDK: \(sh("xcrun --sdk iphoneos --show-sdk-version").first ?? "not installed")",
              ""]

        if !i.deps.isEmpty {
            r += ["### Dependency check"] + i.deps.map { "- \($0.name): \($0.state)" + ($0.detail.isEmpty ? "" : " — \($0.detail)") } + [""]
        }

        if let g = i.game {
            r += ["### Game", "- Folder: \(g)"] + i.gameFiles.map { "  - \($0)" }
            if let k = i.keyCheck { r.append("- Key check: \(k)") }
            r.append("- Target: \(i.platform)")
            r.append("")
        }

        r += ["### Last build", "- Result: \(i.phase)"]
        if let f = i.failure { r.append("- Classified as: \(f)") }
        if let c = i.command { r += ["- Command:", "```", c, "```"] }
        if !i.logTail.isEmpty { r += ["- Last \(i.logTail.count) log lines:", "```"] + i.logTail + ["```"] }

        return sanitize(r.joined(separator: "\n"))
    }

    /// Carpeta de usuario → ~; `nombre = <hex>` → `nombre = <redacted>`; hex de 32+ caracteres → <redacted>.
    static func sanitize(_ s: String) -> String {
        var out = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        out = out.replacing(/(?m)^(\s*[A-Za-z0-9_]+\s*[=:]\s*)[0-9A-Fa-f]{16,}\s*$/) { "\($0.1)<redacted>" }
        out = out.replacing(/[0-9A-Fa-f]{32,}/, with: "<redacted>")
        return out
    }

    static func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private static func q(_ s: String) -> String { shellQuote(s) }

    /// Salida (líneas no vacías) de un comando con el PATH de las dependencias; [] si falla.
    private static func sh(_ cmd: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.environment = Dependencies.env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

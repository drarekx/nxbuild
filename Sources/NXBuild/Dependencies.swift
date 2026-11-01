import Foundation
import AppKit
import Observation

/// Las herramientas que pide build_ipa_from_nsp.py (check_prereqs + README "Install the tools"),
/// cómo comprobarlas y cómo instalarlas.
enum DepID: String, CaseIterable, Identifiable {
    case brew, xcode, metal, iosSDK, brewTools, dotnet, python, pyModules
    var id: String { rawValue }

    var title: String {
        switch self {
        case .brew: "Homebrew"
        case .xcode: "Xcode"
        case .metal: "Metal Toolchain"
        case .iosSDK: "Plataforma iOS de Xcode"
        case .brewTools: "xcodegen, zstd, glslang"
        case .dotnet: ".NET SDK 10"
        case .python: "Python 3.12+ (arm64, venv)"
        case .pyModules: "Módulos Python"
        }
    }

    /// Solo hace falta para la IPA de iPhone.
    var iosOnly: Bool { self == .iosSDK }
}

struct DepStatus {
    enum State { case unknown, checking, ok, warning, missing }
    var state: State = .unknown
    var detail: String = ""
    var action: DepAction? = nil
}

enum DepAction {
    case inApp(label: String, steps: [InstallStep])   // se ejecuta dentro de la app, con log
    case terminal(label: String, command: String)     // necesita contraseña (sudo): se abre en Terminal
    case link(label: String, url: URL)                // instalación manual

    var label: String {
        switch self {
        case .inApp(let l, _), .terminal(let l, _), .link(let l, _): l
        }
    }
}

enum InstallStep {
    case shell(String)                 // /bin/zsh -c
    case createVenv                    // crea el venv local y lo selecciona en Ajustes
    case pipInstall(optional: Bool)    // en el Python de Ajustes
    case usePython(String)             // poner en Ajustes otro Python que ya vale
}

let requiredPyPackages = ["lz4", "capstone>=5,<6", "fonttools", "backports.zstd; python_version < '3.14'"]
let optionalPyPackages = ["nsz", "zbic"]   // nsz: juegos en .nsz/.xcz; zbic: módulos ZBIC de sistema 22+

@MainActor @Observable
final class Dependencies {
    var status: [DepID: DepStatus] = [:]
    var checking = false
    var installing = false
    var installLog: [LogLine] = []
    var currentInstall: String?
    /// Los intérpretes probados en la última comprobación (para deps-check.txt y crear el venv).
    var pythonProbes: [PythonFinder.Probe] = []

    static var reportURL: URL { venvDir.deletingLastPathComponent().appendingPathComponent("deps-check.txt") }

    nonisolated static let venvDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NXBuild/venv")
    nonisolated static var env: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/share/dotnet", NSHomeDirectory() + "/.dotnet"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    func state(_ id: DepID) -> DepStatus { status[id] ?? DepStatus() }

    /// Faltan cosas imprescindibles para construir en esta plataforma.
    func blocking(for platform: Platform) -> [DepID] {
        DepID.allCases.filter { id in
            (platform == .ios || !id.iosOnly) && state(id).state == .missing
        }
    }

    var missingAny: Bool { DepID.allCases.contains { state($0).state == .missing } }

    // MARK: - Comprobación

    func check(settings: AppSettings) async {
        guard !checking else { return }
        checking = true
        for id in DepID.allCases { status[id, default: DepStatus()].state = .checking }
        let python = settings.pythonPath
        let (results, probes) = await Task.detached { Self.runChecks(python: python) }.value
        for (id, st) in results { status[id] = st }
        pythonProbes = probes
        writeReport()
        checking = false
    }

    nonisolated private static func runChecks(python: String) -> ([DepID: DepStatus], [PythonFinder.Probe]) {
        var r: [DepID: DepStatus] = [:]
        let fm = FileManager.default
        let hasBrew = fm.isExecutableFile(atPath: "/opt/homebrew/bin/brew")

        // Homebrew
        r[.brew] = hasBrew
            ? DepStatus(state: .ok, detail: "/opt/homebrew")
            : DepStatus(state: .missing, detail: "No instalado",
                        action: .terminal(label: "Instalar en Terminal",
                                          command: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#))

        // Xcode
        let dev = sh("xcode-select -p").out.trimmingCharacters(in: .whitespacesAndNewlines)
        let xv = sh("xcodebuild -version")
        if dev.contains("CommandLineTools") || xv.code != 0 {
            let app = ["/Applications/Xcode-27.2.app", "/Applications/Xcode.app"].first { fm.fileExists(atPath: $0) }
            if let app {
                r[.xcode] = DepStatus(state: .missing, detail: "Seleccionadas las Command Line Tools (\(dev))",
                                      action: .terminal(label: "Seleccionar Xcode", command: "sudo xcode-select -s \(app) && sudo xcodebuild -license accept"))
            } else {
                r[.xcode] = DepStatus(state: .missing, detail: "Xcode no instalado",
                                      action: .link(label: "Descargar Xcode 27.2", url: URL(string: "https://developer.apple.com/download/all/?q=Xcode%2027.2")!))
            }
        } else {
            let v = xv.out.split(separator: "\n").first.map(String.init) ?? "Xcode"
            r[.xcode] = v.hasPrefix("Xcode 27.2")
                ? DepStatus(state: .ok, detail: v)
                : DepStatus(state: .warning, detail: "\(v) (el probado es 27.2)",
                            action: .link(label: "Descargar 27.2", url: URL(string: "https://developer.apple.com/download/all/?q=Xcode%2027.2")!))
        }
        let xcodeOK = r[.xcode]?.state != .missing

        // Metal
        let mtl = sh("xcrun -sdk macosx metal --version")
        r[.metal] = mtl.code == 0
            ? DepStatus(state: .ok, detail: mtl.out.split(separator: "\n").first.map(String.init) ?? "")
            : DepStatus(state: .missing, detail: "El compilador Metal no arranca",
                        action: xcodeOK ? .inApp(label: "Instalar", steps: [.shell("xcodebuild -downloadComponent MetalToolchain")]) : nil)

        // Plataforma iOS
        let ios = sh("xcrun --sdk iphoneos --show-sdk-version")
        r[.iosSDK] = ios.code == 0
            ? DepStatus(state: .ok, detail: "iOS SDK " + ios.out.trimmingCharacters(in: .whitespacesAndNewlines))
            : DepStatus(state: .missing, detail: "Sin SDK de iOS (solo hace falta para IPA)",
                        action: xcodeOK ? .inApp(label: "Instalar", steps: [.shell("xcodebuild -downloadPlatform iOS")]) : nil)

        // xcodegen, zstd, glslang
        let tools = [("xcodegen", "xcodegen"), ("zstd", "zstd"), ("glslangValidator", "glslang")]
        let gone = tools.filter { sh("command -v \($0.0)").code != 0 }.map(\.1)
        r[.brewTools] = gone.isEmpty
            ? DepStatus(state: .ok, detail: "Instaladas")
            : DepStatus(state: .missing, detail: "Faltan: " + gone.joined(separator: ", "),
                        action: hasBrew ? .inApp(label: "Instalar", steps: [.shell("brew install " + gone.joined(separator: " "))]) : nil)

        // .NET 10
        let sdks = sh("dotnet --list-sdks").out
        let net10 = sdks.split(separator: "\n").first { $0.hasPrefix("10.") }
        r[.dotnet] = net10 != nil
            ? DepStatus(state: .ok, detail: String(net10!).components(separatedBy: " [").first ?? "")
            : DepStatus(state: .missing, detail: sdks.isEmpty ? "dotnet no instalado" : "Sin SDK 10",
                        action: hasBrew ? .terminal(label: "Instalar en Terminal", command: "brew install --cask dotnet-sdk") : nil)

        // Python: el de Ajustes y, si no vale, cualquier otro instalado que sí valga.
        let venvPy = venvDir.appendingPathComponent("bin/python3").path
        let createVenv = DepAction.inApp(label: fm.fileExists(atPath: venvPy) ? "Usar venv local" : "Crear venv local",
                                         steps: [.createVenv, .pipInstall(optional: false), .pipInstall(optional: true)])
        let probes = PythonFinder.candidates(configured: python, venv: venvPy).map(PythonFinder.probe)
        let current = probes.first { $0.path == python } ?? PythonFinder.Probe(path: python)
        let other = probes.first { $0.usable && $0.path != python }
        func short(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        let useOther = other.map { DepAction.inApp(label: "Usar \(short($0.path))", steps: [.usePython($0.path)]) }

        if !fm.isExecutableFile(atPath: python) {
            r[.python] = DepStatus(state: .missing, detail: "No encuentro \(python)", action: useOther ?? createVenv)
        } else if !current.runs {
            r[.python] = DepStatus(state: .missing, detail: "\(python) no arranca", action: useOther ?? createVenv)
        } else if !current.modernARM {
            r[.python] = DepStatus(state: .missing, detail: current.verdict, action: useOther ?? createVenv)
        } else {
            r[.python] = DepStatus(state: .ok, detail: "Python \(current.versionString) arm64" + (current.isVenv ? ", venv" : "") + " — \(short(python))")
        }
        guard current.modernARM else {
            r[.pyModules] = DepStatus(state: .missing, detail: "Sin un Python que valga")
            return (r, probes)
        }

        let pipAction: DepAction = current.isVenv
            ? .inApp(label: "Instalar", steps: [.pipInstall(optional: false), .pipInstall(optional: true)])
            : (useOther ?? createVenv)   // pip en un Python de sistema/Homebrew choca con PEP 668
        if !current.missing.isEmpty {
            var detail = "Faltan: " + current.missing.joined(separator: ", ")
            if let other { detail += " — \(short(other.path)) ya los tiene" }
            else if !current.isVenv { detail += " — no es un venv, se creará uno local" }
            r[.pyModules] = DepStatus(state: .missing, detail: detail, action: other != nil ? useOther : pipAction)
        } else if !current.optionalMissing.isEmpty {
            r[.pyModules] = DepStatus(state: .warning, detail: "Opcionales sin instalar: " + current.optionalMissing.joined(separator: ", ") + " (NSZ/XCZ, ZBIC)",
                                      action: current.isVenv ? .inApp(label: "Instalar", steps: [.pipInstall(optional: true)]) : nil)
        } else {
            r[.pyModules] = DepStatus(state: .ok, detail: "lz4, capstone 5, fonttools, zstd, nsz, zbic")
        }
        return (r, probes)
    }


    nonisolated private static func sh(_ cmd: String) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// deps-check.txt junto al venv: el veredicto de cada fila, los intérpretes probados y el HOME y PATH con que se
    /// comprobó. Es el archivo a mirar cuando la app y la terminal no están de acuerdo (Finder da otro PATH que la shell).
    private func writeReport() {
        var lines = ["NX Build — comprobación de dependencias", "Fecha: \(Date().formatted(.iso8601))", ""]
        for id in DepID.allCases {
            let st = state(id)
            lines.append("\(id.title): \(st.state)" + (st.detail.isEmpty ? "" : " — \(st.detail)"))
        }
        lines += ["", "Intérpretes de Python probados (en orden de preferencia):"]
        lines += pythonProbes.map { "  \($0.path): \($0.verdict)" }
        let env = Self.env
        lines += ["", "HOME=\(env["HOME"] ?? "")", "PATH=\(env["PATH"] ?? "")"]
        try? FileManager.default.createDirectory(at: Self.reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: Self.reportURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Instalación

    func perform(_ action: DepAction, for id: DepID, settings: AppSettings) async {
        switch action {
        case .link(_, let url):
            NSWorkspace.shared.open(url)
        case .terminal(_, let command):
            openInTerminal(command, title: id.title)
        case .inApp(_, let steps):
            guard !installing else { return }
            installing = true
            currentInstall = id.title
            log("== \(id.title) ==", .note)
            let ok = await run(steps, settings: settings)
            log(ok ? "✓ \(id.title)" : "✗ \(id.title) falló", ok ? .note : .error)
            installing = false
            currentInstall = nil
            await check(settings: settings)
        }
    }

    /// Instala en orden todo lo que se puede hacer sin contraseña; lo que la necesita se abre en un solo Terminal.
    func installAll(settings: AppSettings) async {
        guard !installing else { return }
        var terminal: [String] = []
        var steps: [(DepID, [InstallStep])] = []
        var venvQueued = false
        for id in DepID.allCases {
            let st = state(id)
            guard st.state == .missing || (id == .pyModules && st.state == .warning), let a = st.action else { continue }
            switch a {
            case .terminal(_, let c): terminal.append(c)
            case .inApp(_, let s):
                if s.contains(where: { if case .createVenv = $0 { true } else { false } }) {
                    if venvQueued { continue }
                    venvQueued = true
                }
                steps.append((id, s))
            case .link(_, let url): NSWorkspace.shared.open(url)
            }
        }
        if !terminal.isEmpty {
            openInTerminal(terminal.joined(separator: " && "), title: "dependencias")
        }
        guard !steps.isEmpty else { return }
        installing = true
        for (id, s) in steps {
            currentInstall = id.title
            log("== \(id.title) ==", .note)
            let ok = await run(s, settings: settings)
            log(ok ? "✓ \(id.title)" : "✗ \(id.title) falló", ok ? .note : .error)
        }
        installing = false
        currentInstall = nil
        await check(settings: settings)
    }

    private func run(_ steps: [InstallStep], settings: AppSettings) async -> Bool {
        for step in steps {
            switch step {
            case .shell(let cmd):
                guard await stream(cmd) == 0 else { return false }
            case .createVenv:
                let py = Self.venvDir.appendingPathComponent("bin/python3").path
                if !FileManager.default.isExecutableFile(atPath: py) {
                    guard let base = await baseInterpreter() else { return false }
                    try? FileManager.default.createDirectory(at: Self.venvDir.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard await stream("\(shellQuote(base)) -m venv \(shellQuote(Self.venvDir.path))") == 0 else { return false }
                    guard await stream("\(shellQuote(py)) -m pip install --upgrade pip") == 0 else { return false }
                }
                settings.pythonPath = py
                log("Python en Ajustes → \(py)", .note)
            case .usePython(let path):
                settings.pythonPath = path
                log("Python en Ajustes → \(path)", .note)
            case .pipInstall(let optional):
                let pkgs = optional ? optionalPyPackages : requiredPyPackages
                let cmd = "\(shellQuote(settings.pythonPath)) -m pip install " + pkgs.map(shellQuote).joined(separator: " ")
                let code = await stream(cmd)
                if code != 0 {
                    if optional { log("Los opcionales no se instalaron; la build funciona sin ellos salvo NSZ/XCZ.", .note) }
                    else { return false }
                }
            }
        }
        return true
    }

    /// El mejor Python arm64 ≥ 3.12 instalado (uv, pyenv, python.org, Homebrew…) para crear el venv; si no hay, instala python@3.14.
    private func baseInterpreter() async -> String? {
        if let base = PythonFinder.bestBase(pythonProbes) {
            log("Base del venv: \(base.path) (Python \(base.versionString))", .note)
            return base.path
        }
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") else {
            log("No hay Python 3.12+ de Homebrew y Homebrew no está instalado.", .error)
            return nil
        }
        guard await stream("brew install python@3.14") == 0 else { return nil }
        return "/opt/homebrew/bin/python3.14"
    }

    private func stream(_ cmd: String) async -> Int32 {
        log("$ " + cmd, .note)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd + " 2>&1"]
        p.environment = Self.env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch {
            log("No se pudo lanzar: \(error.localizedDescription)", .error); return -1
        }
        await readLines(pipe.fileHandleForReading) { self.log($0, .info) }
        await Task.detached { p.waitUntilExit() }.value
        if p.terminationStatus != 0 { log("código \(p.terminationStatus)", .error) }
        return p.terminationStatus
    }

    private func openInTerminal(_ command: String, title: String) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NXBuild")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("instalar.command")
        let script = """
        #!/bin/zsh
        export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/share/dotnet:$PATH"
        echo "NX Build — instalando \(title)"
        echo "$ \(command.replacingOccurrences(of: "\"", with: "\\\""))"
        echo
        \(command)
        code=$?
        echo
        if (( code == 0 )); then echo "Hecho. Vuelve a NX Build y pulsa Comprobar."; else echo "Terminó con código $code."; fi
        """
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
            log("Abierto en Terminal: \(command)", .note)
        } catch {
            log("No se pudo abrir Terminal: \(error.localizedDescription)", .error)
        }
    }

    private func log(_ text: String, _ kind: LogLine.Kind) {
        installLog.append(LogLine(text: text, kind: kind))
        if installLog.count > 5000 { installLog.removeFirst(installLog.count - 5000) }
    }
}

func shellQuote(_ s: String) -> String {
    s.range(of: #"^[A-Za-z0-9_./=:,+-]+$"#, options: .regularExpression) != nil ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

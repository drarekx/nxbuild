import Foundation

/// Busca un Python que sirva para construir. Una app abierta desde Finder no hereda el PATH de la terminal, así que no
/// basta con `which`: se mira donde se instalan de verdad (uv, pyenv, python.org, Homebrew…) y se prueba cada uno.
enum PythonFinder {
    struct Probe: Sendable, Equatable {
        var path: String
        var runs = false
        var version: [Int] = []
        var machine = ""
        var isVenv = false
        var missing: [String] = []          // módulos imprescindibles que faltan
        var optionalMissing: [String] = []  // nsz, zbic

        var versionString: String { version.map(String.init).joined(separator: ".") }
        var modernARM: Bool { runs && !version.lexicographicallyPrecedes([3, 12]) && machine == "arm64" }
        /// Vale para construir: 3.12+, arm64 y con todos los módulos imprescindibles.
        var usable: Bool { modernARM && missing.isEmpty }

        var verdict: String {
            guard runs else { return "no arranca" }
            var s = "Python \(versionString) \(machine)" + (isVenv ? " venv" : "")
            if version.lexicographicallyPrecedes([3, 12]) { s += " — demasiado viejo" }
            else if machine != "arm64" { s += " — no es arm64 (Rosetta)" }
            else if !missing.isEmpty { s += " — faltan " + missing.joined(separator: ", ") }
            else { s += " — vale" }
            return s
        }
    }

    /// Dónde buscar, en orden de preferencia: el de Ajustes, el venv local, y luego los instalados.
    static func candidates(configured: String, venv: String, home: String = NSHomeDirectory(),
                           env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let fm = FileManager.default
        var out: [String] = [configured, venv]
        func children(_ dir: String, _ suffix: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted(by: newestFirst).map { "\(dir)/\($0)/\(suffix)" }
        }
        // uv (`uv python install`): ~/.local/share/uv/python/cpython-3.13.x-macos-aarch64-none/bin/python3
        let uvDir = env["UV_PYTHON_INSTALL_DIR"] ?? home + "/.local/share/uv/python"
        out += children(uvDir, "bin/python3").filter { $0.contains("cpython") }
        out += ["3.14", "3.13", "3.12", "3.15"].map { home + "/.local/bin/python\($0)" }
        out += children(home + "/.pyenv/versions", "bin/python3")
        out += children("/Library/Frameworks/Python.framework/Versions", "bin/python3")
        out += ["3.14", "3.13", "3.12", "3.15"].map { "/opt/homebrew/bin/python\($0)" } + ["/opt/homebrew/bin/python3"]
        out += ["3.14", "3.13", "3.12"].map { "/usr/local/bin/python\($0)" } + ["/usr/local/bin/python3", "/usr/bin/python3"]

        var seen = Set<String>(), result: [String] = []
        for p in out where !p.isEmpty && fm.isExecutableFile(atPath: p) {
            let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
            // Un venv enlaza a su intérprete base: se distingue por su propia ruta, no por la real.
            let key = p.contains("/venv/") || p.hasPrefix(venv) || p == configured ? p : real
            if seen.insert(key).inserted { result.append(p) }
        }
        return result
    }

    /// "3.13.2" antes que "3.12.9"; los nombres sin versión al final.
    private static func newestFirst(_ a: String, _ b: String) -> Bool {
        func ver(_ s: String) -> [Int] {
            guard let m = s.firstMatch(of: /(\d+)\.(\d+)(?:\.(\d+))?/) else { return [] }
            return [Int(m.1) ?? 0, Int(m.2) ?? 0, Int(m.3 ?? "0") ?? 0]
        }
        return ver(b).lexicographicallyPrecedes(ver(a))
    }

    static func probe(_ path: String) -> Probe {
        var p = Probe(path: path)
        let r = Shell.run(shellQuote(path) + " -c " + shellQuote(script), timeout: 20)
        guard r.code == 0, let data = r.out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return p }
        p.runs = true
        p.version = j["ver"] as? [Int] ?? []
        p.machine = j["machine"] as? String ?? "?"
        p.isVenv = j["venv"] as? Bool ?? false
        let mods = j["mods"] as? [String: Any] ?? [:]
        if mods["lz4"] as? Bool != true { p.missing.append("lz4") }
        if mods["fonttools"] as? Bool != true { p.missing.append("fonttools") }
        if mods["zstd"] as? Bool != true { p.missing.append("backports.zstd") }
        switch mods["capstone"] as? Int {
        case 5?: break
        case let v?: p.missing.append("capstone 5.x (hay \(v).x)")
        default: p.missing.append("capstone")
        }
        if mods["nsz"] as? Bool != true { p.optionalMissing.append("nsz") }
        if mods["zbic"] as? Bool != true { p.optionalMissing.append("zbic") }
        return p
    }

    /// El intérprete base para crear un venv: el más nuevo 3.12+ arm64 que no sea un venv (prefiriendo 3.12–3.14,
    /// que tienen ruedas de todos los módulos; 3.15 al final).
    static func bestBase(_ probes: [Probe]) -> Probe? {
        let ok = probes.filter { $0.modernARM && !$0.isVenv }
        let preferred = ok.filter { $0.version.count >= 2 && $0.version[1] <= 14 }
        return (preferred.isEmpty ? ok : preferred).max { $0.version.lexicographicallyPrecedes($1.version) }
    }

    static let script = """
    import sys, json, platform, importlib.util as u
    def has(m):
        try: return u.find_spec(m) is not None
        except Exception: return False
    try:
        import capstone; cap = capstone.cs_version()[0]
    except Exception: cap = None
    print(json.dumps({"ver": list(sys.version_info[:3]), "machine": platform.machine(), "venv": sys.prefix != sys.base_prefix,
      "mods": {"lz4": has("lz4.block"), "fonttools": has("fontTools"), "zstd": has("compression.zstd") or has("backports.zstd"),
               "capstone": cap, "nsz": has("nsz"), "zbic": has("zbic")}}))
    """
}

/// Ejecuta un comando de zsh con el PATH de las dependencias.
enum Shell {
    static func run(_ cmd: String, timeout: Double = 60) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.environment = Dependencies.env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

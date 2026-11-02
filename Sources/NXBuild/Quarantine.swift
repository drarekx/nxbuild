import Foundation

/// La marca com.apple.quarantine que macOS pone a lo que llega de fuera (AirDrop, navegador, zip descargado).
/// Las apps de juego de nxnative solo llevan firma ad hoc: con la marca, Gatekeeper las rechaza
/// («no se puede comprobar el desarrollador» / «está dañada»). Quitarla es lo mismo que «Abrir igualmente»
/// en Ajustes › Privacidad y seguridad, pero de una vez para todo el bundle.
enum Quarantine {
    static let attribute = "com.apple.quarantine"

    static func isSet(_ path: String) -> Bool {
        getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// En una carpeta sincronizada (iCloud Drive), tocar cada archivo puede obligar a descargarlo antes.
    static func isInSyncedFolder(_ path: String) -> Bool {
        path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/")
    }

    enum Failure: LocalizedError {
        case readOnlyVolume(String)
        case cancelled
        case failed(String, String)
        var errorDescription: String? {
            switch self {
            case .readOnlyVolume(let p):
                "«\(p)» está en un disco de solo lectura (una imagen de disco o una carpeta compartida)."
            case .cancelled:
                "No se ha cambiado nada: hace falta la contraseña de administrador para permitir esta app."
            case .failed(let p, let why):
                "No se pudo permitir «\(p)»: \(why)"
            }
        }
    }

    /// Quita la marca de la app y de todo lo que contiene (xattr -dr). La marca es un atributo extendido, no forma
    /// parte de lo firmado: la firma sigue valiendo.
    /// Primero como el usuario; si la app es de otro usuario o de root, o sus archivos son de solo lectura (borrar un
    /// atributo exige permiso de escritura en cada archivo), lo repite como administrador: macOS pide la contraseña.
    /// `status` recibe el paso en curso (para enseñarlo: con miles de archivos tarda).
    nonisolated static func remove(from path: String, status: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let name = (path as NSString).lastPathComponent
        if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            throw Failure.readOnlyVolume(name)
        }
        try await Task.detached {
            status(isInSyncedFolder(path) ? "Quitando la marca… (en la nube: puede tener que descargar el juego)" : "Quitando la marca…")
            _ = run("/usr/bin/xattr", ["-dr", attribute, path])
            guard isSet(path) || anyInside(path) else { return }
            status("Esperando la contraseña de administrador…")
            // Como administrador. La ruta va como argumento (quoted form), nunca dentro del texto del script.
            // 2>&1 y exit 0: los errores de xattr vuelven como resultado del script (stdout) en vez de cortar osascript.
            let script = [
                "on run argv",
                "do shell script \"/usr/bin/xattr -dr \(attribute) \" & quoted form of item 1 of argv & \" 2>&1; exit 0\" with administrator privileges",
                "end run",
            ]
            let (code, out) = run("/usr/bin/osascript", script.flatMap { ["-e", $0] } + [path])
            if out.contains("-128") { throw Failure.cancelled }   // userCanceledErr
            if isSet(path) || anyInside(path) {
                throw Failure.failed(name, summary(out) ?? "la marca sigue ahí después de quitarla como administrador (osascript \(code)). Puede que macOS proteja esa carpeta o que se sincronice y vuelva a ponerla.")
            }
        }.value
    }

    /// Plan B cuando la marca no se deja quitar: copia la app a `folder` (~/Applications) con archivos nuevos a nombre
    /// del usuario, les da permiso de escritura y les quita la marca. Ni ditto (hace enlaces duros: comparten la marca
    /// con el original) ni cp -X (macOS vuelve a poner la marca a los clones) sirven solos; cp -R + chmod + xattr sí.
    /// `progress` recibe la fracción copiada (por número de archivos). Devuelve la ruta de la copia.
    nonisolated static func cleanCopy(of path: String, into folder: String,
                                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> String {
        let fm = FileManager.default
        let name = (path as NSString).lastPathComponent
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        var dest = (folder as NSString).appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: dest) {
            dest = (folder as NSString).appendingPathComponent("\(base) \(n).app"); n += 1
        }
        let target = dest
        try await Task.detached {
            var count = 1
            if let e = fm.enumerator(atPath: path) { while e.nextObject() != nil { count += 1 } }
            let total = count
            let (st, out) = run("/bin/cp", ["-R", "-v", path, target]) { lines in
                progress(min(0.99, Double(lines) / Double(total)))
            }
            guard st == 0 else {
                _ = run("/bin/chmod", ["-R", "u+w", target]); try? fm.removeItem(atPath: target)
                throw Failure.failed(name, "no se pudo copiar: " + (summary(out.split(separator: "\n").filter { $0.hasPrefix("cp:") }.joined(separator: "\n")) ?? "cp terminó con \(st)"))
            }
            _ = run("/bin/chmod", ["-R", "u+w", target])
            _ = run("/usr/bin/xattr", ["-dr", attribute, target])
            if isSet(target) || anyInside(target) {
                throw Failure.failed(name, "la copia en \(target) también conserva la marca.")
            }
            progress(1)
        }.value
        return target
    }

    /// Las primeras líneas de error, sin repetir el mismo «Permission denied» miles de veces.
    private static func summary(_ out: String) -> String? {
        let lines = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let head = lines.prefix(3).joined(separator: "\n")
        return lines.count > 3 ? head + "\n(y \(lines.count - 3) líneas más)" : head
    }

    /// ¿Queda la marca en el ejecutable principal o en el resto de Contents/MacOS? (lo que Gatekeeper mira al abrir)
    private static func anyInside(_ app: String) -> Bool {
        let dir = app + "/Contents/MacOS"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).contains { isSet(dir + "/" + $0) }
    }

    /// Ejecuta y devuelve (código, salida). stdout y stderr juntos, leídos mientras corre (sin bloquear por un pipe
    /// lleno); `onLines` recibe el número de líneas leídas hasta el momento.
    private static func run(_ exe: String, _ args: [String], onLines: (@Sendable (Int) -> Void)? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        var data = Data(), lines = 0, lastReport = Date.distantPast
        let h = pipe.fileHandleForReading
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            if onLines != nil {
                lines += chunk.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                if Date().timeIntervalSince(lastReport) > 0.25 { onLines?(lines); lastReport = Date() }
            } else {
                data.append(chunk)
            }
            if onLines != nil, data.count < 64_000 { data.append(chunk) }   // basta con el principio para los errores
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

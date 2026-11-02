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

    enum Failure: LocalizedError {
        case readOnlyVolume(String)
        case cancelled
        case failed(String, String)
        var errorDescription: String? {
            switch self {
            case .readOnlyVolume(let p):
                "«\(p)» está en un disco de solo lectura (una imagen de disco o una carpeta compartida). Cópiala a Aplicaciones y vuelve a probar."
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
    nonisolated static func remove(from path: String) async throws {
        let name = (path as NSString).lastPathComponent
        if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            throw Failure.readOnlyVolume(name)
        }
        try await Task.detached {
            _ = run("/usr/bin/xattr", ["-dr", attribute, path])
            guard isSet(path) || anyInside(path) else { return }
            // Como administrador. La ruta va como argumento (quoted form), nunca dentro del texto del script.
            // 2>&1 y exit 0: los errores de xattr vuelven como resultado del script (stdout) en vez de cortar osascript.
            let script = [
                "on run argv",
                "do shell script \"/usr/bin/xattr -dr \(attribute) \" & quoted form of item 1 of argv & \" 2>&1; exit 0\" with administrator privileges",
                "end run",
            ]
            let (status, out) = run("/usr/bin/osascript", script.flatMap { ["-e", $0] } + [path])
            if out.contains("-128") { throw Failure.cancelled }   // userCanceledErr
            if isSet(path) || anyInside(path) {
                throw Failure.failed(name, summary(out) ?? "la marca sigue ahí después de quitarla como administrador (osascript \(status)). Puede que macOS proteja esa carpeta o que se sincronice y vuelva a ponerla.")
            }
        }.value
    }

    /// Plan B cuando la marca no se deja quitar: copia la app a `folder` (por defecto ~/Applications), deja la copia a
    /// nombre del usuario y escribible y le quita la marca. ditto conserva la firma y los permisos de ejecución, pero
    /// también copia la cuarentena (incluso con --noqtn), por eso se limpia después. Devuelve la ruta de la copia.
    nonisolated static func cleanCopy(of path: String, into folder: String) async throws -> String {
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
            let (st, out) = run("/usr/bin/ditto", ["--noqtn", path, target])
            guard st == 0 else {
                _ = run("/bin/chmod", ["-R", "u+w", target]); try? fm.removeItem(atPath: target)
                throw Failure.failed(name, "no se pudo copiar: " + (summary(out) ?? "ditto terminó con \(st)"))
            }
            _ = run("/bin/chmod", ["-R", "u+w", target])
            _ = run("/usr/bin/xattr", ["-dr", attribute, target])
            if isSet(target) || anyInside(target) {
                throw Failure.failed(name, "la copia en \(target) también conserva la marca.")
            }
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

    private static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let err = Pipe()   // stdout y stderr juntos
        p.standardError = err
        p.standardOutput = err
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

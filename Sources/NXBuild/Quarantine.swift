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
            let script = [
                "on run argv",
                "do shell script \"/usr/bin/xattr -dr \(attribute) \" & quoted form of item 1 of argv & \"; exit 0\" with administrator privileges",
                "end run",
            ]
            let (status, err) = run("/usr/bin/osascript", script.flatMap { ["-e", $0] } + [path])
            if err.contains("-128") { throw Failure.cancelled }   // userCanceledErr
            if isSet(path) || anyInside(path) {
                throw Failure.failed(name, err.isEmpty ? "osascript terminó con \(status)" : err)
            }
        }.value
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
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

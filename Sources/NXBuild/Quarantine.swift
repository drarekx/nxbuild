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
        case notWritable(String)
        case failed(String, String)
        var errorDescription: String? {
            switch self {
            case .notWritable(let p):
                "No tienes permiso para cambiar «\(p)». Muévela a una carpeta tuya (por ejemplo Aplicaciones) y vuelve a probar."
            case .failed(let p, let why):
                "No se pudo permitir «\(p)»: \(why)"
            }
        }
    }

    /// Quita la marca de la app y de todo lo que contiene (xattr -dr). Sin tocar la firma: la marca es un atributo
    /// extendido, no forma parte de lo firmado.
    nonisolated static func remove(from path: String) async throws {
        let name = (path as NSString).lastPathComponent
        guard FileManager.default.isWritableFile(atPath: path) else { throw Failure.notWritable(name) }
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            p.arguments = ["-dr", attribute, path]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // xattr -dr termina con error si algún archivo ya no tenía la marca; lo que cuenta es el resultado.
            if isSet(path) { throw Failure.failed(name, msg.isEmpty ? "xattr terminó con \(p.terminationStatus)" : msg) }
        }.value
    }
}

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

    /// Lo que se está haciendo, para enseñarlo: paso, archivos hechos de cuántos y el archivo en curso.
    struct Progress: Sendable, Equatable {
        var step: String
        var done = 0
        var total = 0          // 0: sin total conocido (barra indeterminada)
        var current = ""       // ruta relativa dentro de la app
        /// done y total cuentan archivos, o MB (GameMove).
        enum Unit: Sendable { case files, megabytes }
        var unit: Unit = .files
        var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }
    }
    typealias Report = @Sendable (Progress) -> Void

    enum Failure: LocalizedError {
        case readOnlyVolume(String)
        /// EPERM: la protección «Gestión de apps» de macOS no deja a NX Build cambiar otra app, ni como root.
        case protectedByMacOS(String, String)
        case cancelled
        case failed(String, String)
        var errorDescription: String? {
            switch self {
            case .readOnlyVolume(let p):
                "«\(p)» está en un disco de solo lectura (una imagen de disco o una carpeta compartida)."
            case .protectedByMacOS(let p, let first):
                "macOS protege «\(p)» (Gestión de apps): no deja que otra app la modifique, ni con la contraseña de administrador.\n\(first)"
            case .cancelled:
                "Cancelado: no se ha terminado de permitir la app."
            case .failed(let p, let why):
                "No se pudo permitir «\(p)»: \(why)"
            }
        }
    }

    /// Quita la marca de la app y de todo lo que contiene, archivo a archivo (removexattr) para poder informar del
    /// avance y cancelar. La marca es un atributo extendido, no forma parte de lo firmado: la firma sigue valiendo.
    /// Si algún archivo no deja (de otro usuario o de solo lectura: borrar un atributo exige permiso de escritura),
    /// lo repite como administrador con xattr -dr: macOS pide la contraseña.
    /// Se ejecuta fuera del hilo principal (nonisolated async) y respeta la cancelación de la tarea que lo llama.
    nonisolated static func remove(from path: String, report: @escaping Report = { _ in }) async throws {
        let name = (path as NSString).lastPathComponent
        if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            throw Failure.readOnlyVolume(name)
        }
        let step = isInSyncedFolder(path) ? "Quitando la marca (en la nube: puede tener que descargar archivos)" : "Quitando la marca"
        report(Progress(step: "Contando archivos"))
        let items = try list(path)
        var p = Progress(step: step, total: items.count)
        var denied = 0, protected = 0, firstError = ""
        var last = Date.distantPast
        for rel in items {
            try Task.checkCancellation()
            let full = rel.isEmpty ? path : path + "/" + rel
            if removexattr(full, attribute, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
                if errno == EPERM { protected += 1 } else { denied += 1 }
                if firstError.isEmpty { firstError = "\(rel.isEmpty ? name : rel): \(String(cString: strerror(errno)))" }
            }
            p.done += 1
            if Date().timeIntervalSince(last) > 0.1 { p.current = rel; report(p); last = Date() }
        }
        p.current = ""; report(p)
        guard denied > 0 || protected > 0 || isSet(path) || anyInside(path) else { return }
        // EPERM es TCC (Gestión de apps): como administrador da el mismo error, no tiene sentido pedir la contraseña.
        if protected > 0 { throw Failure.protectedByMacOS(name, firstError) }

        report(Progress(step: "\(denied) archivo\(denied == 1 ? "" : "s") sin permiso (\(firstError)). Esperando la contraseña de administrador…"))
        // Como administrador. La ruta va como argumento (quoted form), nunca dentro del texto del script.
        // 2>&1 y exit 0: los errores de xattr vuelven como resultado del script (stdout) en vez de cortar osascript.
        let script = [
            "on run argv",
            "do shell script \"/usr/bin/xattr -dr \(attribute) \" & quoted form of item 1 of argv & \" 2>&1; exit 0\" with administrator privileges",
            "end run",
        ]
        let (code, out) = try run("/usr/bin/osascript", script.flatMap { ["-e", $0] } + [path])
        if out.contains("-128") { throw Failure.cancelled }   // userCanceledErr: canceló la contraseña
        if out.contains("Operation not permitted") { throw Failure.protectedByMacOS(name, summary(out) ?? "") }
        if isSet(path) || anyInside(path) {
            throw Failure.failed(name, summary(out) ?? "la marca sigue ahí después de quitarla como administrador (osascript \(code)). Puede que macOS proteja esa carpeta o que se sincronice y vuelva a ponerla.")
        }
    }

    /// Plan B cuando la marca no se deja quitar (Gestión de apps, permisos): copia la app a `folder` (~/Applications)
    /// con rsync -rlt, que escribe archivos nuevos sin atributos extendidos: la copia nace sin la marca y no hay que
    /// modificarla después (que la Gestión de apps podría impedir). ditto hace enlaces duros que comparten la marca y
    /// cp (con o sin -X) clona los archivos y la marca va con ellos.
    /// Devuelve la ruta de la copia; si se cancela o falla, borra la copia a medias.
    nonisolated static func cleanCopy(of path: String, into folder: String, report: @escaping Report = { _ in }) async throws -> String {
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
        func discard() { _ = try? run("/bin/chmod", ["-R", "u+w", target]); try? fm.removeItem(atPath: target) }

        report(Progress(step: "Contando archivos"))
        let total = try list(path).count
        let step = "Copiando a " + folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        report(Progress(step: step, total: total))
        do {
            // -v escribe una línea por archivo (su ruta relativa): sirve de progreso.
            let (st, out) = try run("/usr/bin/rsync", ["-rlt", "-v", path + "/", target + "/"]) { lines, lastLine in
                report(Progress(step: step, done: min(lines, total), total: total, current: lastLine))
            }
            guard st == 0 else {
                let errs = out.split(whereSeparator: { $0 == "\n" }).filter { $0.contains("rsync") || $0.contains("error") }.joined(separator: "\n")
                throw Failure.failed(name, "no se pudo copiar: " + (summary(errs) ?? "rsync terminó con \(st)"))
            }
            if isSet(target) || anyInside(target) {
                throw Failure.failed(name, "la copia en \(target) también lleva la marca.")
            }
        } catch {
            discard()
            throw error is CancellationError ? Failure.cancelled : error
        }
        return target
    }

    /// Rutas relativas de todo lo que hay en la app ("" es la propia app), sin seguir enlaces simbólicos.
    private static func list(_ path: String) throws -> [String] {
        var out = [""]
        guard let e = FileManager.default.enumerator(atPath: path) else { return out }
        while let rel = e.nextObject() as? String {
            out.append(rel)
            if out.count % 2000 == 0 { try Task.checkCancellation() }
        }
        return out
    }

    /// Las primeras líneas de error, sin repetir el mismo «Permission denied» miles de veces.
    private static func summary(_ out: String) -> String? {
        let lines = out.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let head = lines.prefix(3).joined(separator: "\n")
        return lines.count > 3 ? head + "\n(y \(lines.count - 3) líneas más)" : head
    }

    /// ¿Queda la marca en el ejecutable principal o en el resto de Contents/MacOS? (lo que Gatekeeper mira al abrir)
    private static func anyInside(_ app: String) -> Bool {
        let dir = app + "/Contents/MacOS"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).contains { isSet(dir + "/" + $0) }
    }

    /// Ejecuta y devuelve (código, salida: stdout y stderr juntos, hasta 64 KB). Lee mientras corre (sin bloquear por
    /// un pipe lleno); `onLines` recibe las líneas leídas y la última. Si la tarea se cancela, termina el proceso.
    private static func run(_ exe: String, _ args: [String],
                            onLines: ((Int, String) -> Void)? = nil) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        try p.run()
        var data = Data(), lines = 0, last = Date.distantPast, tail = Data()
        let h = pipe.fileHandleForReading
        while true {
            if Task.isCancelled, p.isRunning { p.terminate() }
            let chunk = h.availableData
            if chunk.isEmpty { break }
            if data.count < 64_000 { data.append(chunk) }
            if let onLines {
                lines += chunk.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                tail.append(chunk)
                if tail.count > 4096 { tail = tail.suffix(4096) }
                if Date().timeIntervalSince(last) > 0.1 {
                    let lastLine = String(decoding: tail, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
                    onLines(lines, lastLine); last = Date()
                }
            }
        }
        p.waitUntilExit()
        if Task.isCancelled { throw CancellationError() }
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

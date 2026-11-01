import Foundation
import AppKit
import Observation

enum Platform: String, CaseIterable, Identifiable {
    case macApp = "mac-app"
    case ios = "ios"
    var id: String { rawValue }
    var label: String { self == .macApp ? "App para Mac" : "IPA para iPhone" }
}

struct StageRow: Identifiable {
    enum State { case running, ok, failed }
    let id: Int          // k
    var name: String
    var step: String = ""
    var state: State = .running
    var summary: String = ""
    var elapsed: Double? = nil
}

struct LogLine: Identifiable {
    enum Kind { case info, note, error, stderr }
    let id = UUID()
    let text: String
    let kind: Kind
}

struct CurrentProgress {
    var done: Double?
    var total: Double?
    var unit: String = ""
    var est = false
    var note: String = ""
    var frac: Double?
    var eta: Double?
    var elapsed: Double?
}

/// Lanza scripts/build_ipa_from_nsp.py con --progress json y traduce sus eventos al estado de la UI.
@MainActor @Observable
final class BuildRunner {
    enum Phase: Equatable { case idle, running, done, failed(Int32), cancelled }

    var phase: Phase = .idle
    var stages: [StageRow] = []
    var totalStages = 0
    var current = CurrentProgress()
    var log: [LogLine] = []
    var startedAt: Date?
    var finishedAt: Date?
    var lastNSPDir: URL?
    /// Donde queda la app o IPA: la carpeta del juego, o la que contiene --work-dir.
    var outputDir: URL?
    /// La carpeta de build cuando se eligió con --work-dir (si no, <title ID>_build en la carpeta del juego).
    var workDir: URL?
    /// Por qué ha fallado la última build (nil si no ha fallado).
    var failure: BuildFailure?
    private var lastKeys: URL?
    private var notify = true
    private var targetLabel = ""
    private(set) var lastPlatform: Platform = .macApp

    private var process: Process?
    private var cancelRequested = false
    /// Grupo de procesos de la build: el script y todo lo que lanza (dotnet, metal, xcodebuild…).
    /// El script es el líder (setpgid(0, 0) antes de execv), así que pgid == pid de Python.
    private(set) var pgid: pid_t = 0

    /// La build en marcha, para que AppDelegate la pare al salir.
    static weak var active: BuildRunner?

    init() { BuildRunner.active = self }

    var isRunning: Bool { phase == .running }

    func start(settings: AppSettings, nspDir: URL, keys: URL?, platform: Platform, options: BuildOptions) {
        guard !isRunning else { return }
        stages = []; totalStages = 0; current = CurrentProgress(); log = []
        startedAt = Date(); finishedAt = nil; lastNSPDir = nspDir; cancelRequested = false
        failure = nil; lastKeys = keys
        notify = settings.notifyOnFinish; targetLabel = platform.label; lastPlatform = platform
        if notify { BuildNotifier.shared.prepare() }
        workDir = options.workDir.isEmpty ? nil : URL(fileURLWithPath: options.workDir)
        outputDir = workDir?.deletingLastPathComponent() ?? nspDir
        if let workDir { try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true) }

        let repo = URL(fileURLWithPath: settings.repoPath)
        let script = repo.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        var args = [script.path, nspDir.path, "--progress", "json"]
        if let keys { args += ["-k", keys.path] }
        if platform == .macApp { args += ["--platform", "mac-app"] }
        args += options.arguments(platform: platform)

        // Python se pone en un grupo de procesos propio y se reemplaza por el script: así cancelar
        // (y salir de la app) llega a todos los hijos con killpg, no solo a Python.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.pythonPath)
        p.arguments = ["-c", "import os, sys; os.setpgid(0, 0); os.execv(sys.argv[1], sys.argv[1:])",
                       settings.pythonPath] + args
        p.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/share/dotnet",
                     NSHomeDirectory() + "/.dotnet"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        append("$ \(([p.executableURL!.path] + args).map(shellQuote).joined(separator: " "))", .note)

        do {
            try p.run()
        } catch {
            append("No se pudo lanzar Python: \(error.localizedDescription)", .error)
            phase = .failed(-1); finishedAt = Date()
            return
        }
        process = p
        pgid = p.processIdentifier
        phase = .running

        let outHandle = out.fileHandleForReading, errHandle = err.fileHandleForReading
        Task {
            let readers = Task {
                async let o: Void = readLines(outHandle) { self.handleStdout($0) }
                async let e: Void = readLines(errHandle) { self.append($0, .stderr) }
                _ = await (o, e)
            }
            await Task.detached { p.waitUntilExit() }.value
            // Un hijo que siga vivo con la salida abierta no debe dejar la UI en «Construyendo…»:
            // tras cancelar se mata lo que quede del grupo, y las tuberías tienen 5 s para vaciarse.
            if self.cancelRequested { killGroup(self.pgid, SIGKILL) }
            let drained = await withTaskGroup(of: Bool.self) { g in
                g.addTask { await readers.value; return true }
                g.addTask { try? await Task.sleep(for: .seconds(5)); return false }
                let first = await g.next() ?? false
                g.cancelAll()
                return first
            }
            if !drained {
                self.append("Quedan procesos de la build con la salida abierta (grupo \(self.pgid)).", .note)
                try? outHandle.close(); try? errHandle.close()
            }
            self.finish(code: p.terminationStatus)
        }
    }

    /// SIGINT a todo el grupo (el script cierra la etapa y sale con 130); si sigue vivo a los 10 s, SIGTERM;
    /// a los 15 s, SIGKILL.
    func cancel() {
        guard isRunning, pgid > 0 else { return }
        cancelRequested = true
        append("Cancelando…", .note)
        let group = pgid
        killGroup(group, SIGINT)
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard groupAlive(group) else { return }
            self.append("Sigue en marcha: SIGTERM al grupo \(group).", .note)
            killGroup(group, SIGTERM)
            try? await Task.sleep(for: .seconds(5))
            guard groupAlive(group) else { return }
            self.append("SIGKILL al grupo \(group).", .note)
            killGroup(group, SIGKILL)
        }
    }

    /// Al salir de la app: para el grupo sin esperar a la etapa (SIGTERM, 2 s de margen, SIGKILL).
    nonisolated static func stopGroupForQuit(_ group: pid_t) {
        guard group > 0, groupAlive(group) else { return }
        killGroup(group, SIGTERM)
        for _ in 0..<20 where groupAlive(group) { usleep(100_000) }
        if groupAlive(group) { killGroup(group, SIGKILL) }
    }

    private func finish(code: Int32) {
        process = nil
        pgid = 0
        DockProgress.set(nil)
        finishedAt = Date()
        if let i = stages.lastIndex(where: { $0.state == .running }) {
            stages[i].state = code == 0 ? .ok : .failed
        }
        if code == 0 {
            phase = .done; append("Hecho.", .note)
        } else if cancelRequested {
            phase = .cancelled; append("Cancelado.", .note)
        } else {
            phase = .failed(code); append("Terminó con código \(code).", .error)
            // Las líneas de error se guardan sin su [RED]: se le devuelve para los patrones que lo usan.
            let raw = log.map { $0.kind == .error ? "[RED] " + $0.text : $0.text }
            failure = BuildFailureClassifier.classify(
                log: raw, inputs: .init(nspDir: lastNSPDir?.path ?? "", keysPath: lastKeys?.path ?? ""))
        }
        if notify, !cancelRequested {
            let game = lastNSPDir?.lastPathComponent ?? "La build"
            if code == 0 {
                BuildNotifier.shared.notify(title: "Build terminada", body: "\(game) · \(targetLabel)", success: true)
            } else {
                BuildNotifier.shared.notify(title: "Build fallida", body: "\(game): \(failure?.title ?? "código \(code)")", success: false)
            }
        }
        NSApp.requestUserAttention(.informationalRequest)
        NSSound(named: code == 0 ? "Glass" : "Basso")?.play()
    }

    // MARK: - Eventos JSON

    private func handleStdout(_ line: String) {
        guard line.first == "{",
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ev = obj["ev"] as? String
        else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { append(line, .info) }
            return
        }
        let k = obj["k"] as? Int ?? 0
        defer { DockProgress.set(DockProgress.overall(stage: stages.last?.id ?? 0, of: totalStages, frac: current.frac) ?? 0) }
        switch ev {
        case "stage":
            if let n = obj["n"] as? Int { totalStages = n }
            stages.append(StageRow(id: k, name: obj["name"] as? String ?? "", step: obj["step"] as? String ?? ""))
            current = CurrentProgress()
        case "step":
            updateStage(k) { $0.step = obj["step"] as? String ?? "" }
            current = CurrentProgress()
        case "progress":
            updateStage(k) { $0.step = obj["step"] as? String ?? $0.step }
            current = CurrentProgress(
                done: num(obj["done"]), total: num(obj["total"]),
                unit: obj["unit"] as? String ?? "", est: obj["est"] as? Bool ?? false,
                note: obj["note"] as? String ?? "", frac: num(obj["frac"]),
                eta: num(obj["eta"]), elapsed: num(obj["elapsed"]))
        case "stage_end":
            updateStage(k) {
                $0.state = (obj["ok"] as? Bool ?? true) ? .ok : .failed
                $0.summary = obj["summary"] as? String ?? ""
                $0.elapsed = num(obj["elapsed"])
            }
            current = CurrentProgress()
        case "say":
            let msg = obj["msg"] as? String ?? ""
            if msg.hasPrefix("[RED] ") { append(String(msg.dropFirst(6)), .error) }
            else if let r = msg.range(of: #"^\[[A-Z]+\] "#, options: .regularExpression) { append(String(msg[r.upperBound...]), .note) }
            else { append(msg, .info) }
        case "shaders_stale":
            let reason = obj["reason"] as? String ?? ""
            let count = obj["count"] as? Int ?? 0
            append("Shaders desactualizados (\(count)): \(reason)", .note)
        default:
            append(line, .info)
        }
    }

    private func updateStage(_ k: Int, _ f: (inout StageRow) -> Void) {
        if let i = stages.lastIndex(where: { $0.id == k }) { f(&stages[i]) }
    }

    private func append(_ text: String, _ kind: LogLine.Kind) {
        log.append(LogLine(text: text, kind: kind))
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }
}

private func killGroup(_ group: pid_t, _ sig: Int32) {
    if group > 0 { killpg(group, sig) }
}

/// ¿Queda algún proceso en el grupo? (killpg con señal 0 solo comprueba).
private func groupAlive(_ group: pid_t) -> Bool {
    group > 0 && killpg(group, 0) == 0
}

private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }


/// Lee un descriptor línea a línea fuera del hilo principal y entrega cada línea en el actor principal.
func readLines(_ handle: FileHandle, _ onLine: @escaping @MainActor (String) -> Void) async {
    let stream = AsyncStream<String> { cont in
        Thread.detachNewThread {
            var buf = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 0x0A) {
                    let lineData = buf[buf.startIndex..<nl]
                    buf.removeSubrange(buf.startIndex...nl)
                    cont.yield(String(decoding: lineData, as: UTF8.self))
                }
            }
            if !buf.isEmpty { cont.yield(String(decoding: buf, as: UTF8.self)) }
            cont.finish()
        }
    }
    for await line in stream { await onLine(line) }
}

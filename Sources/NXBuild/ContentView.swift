import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BuildRunner.self) private var runner
    @Environment(Dependencies.self) private var deps
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var nspDir = ""
    @State private var keysPath = ""
    @State private var platform: Platform = .macApp
    @State private var options = BuildOptions()
    @State private var metal: MetalCheck?
    @State private var showOptions = false
    @State private var dropTargeted = false
    @State private var keyCheck: KeyCheck?
    @State private var selection: GameSelection?
    @State private var dropMessage: String?
    @State private var showFreeSpace = false
    @State private var diagCopied = false
    @State private var keyChecking = false
    @State private var cloud: CloudFolder.Info?
    @State private var buildLocally = false

    var body: some View {
        HSplitView {
            setupPane
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
            progressPane
                .frame(minWidth: 420)
        }
        .task {
            nspDir = settings.lastNSPDir
            keysPath = settings.keysPath
            metal = await MetalCheck.run(repoPath: settings.repoPath)
            await deps.check(settings: settings)
        }
        .task(id: "\(nspDir)|\(keysPath)") { await runKeyCheck() }
        .task(id: nspDir) { await runCloudCheck() }
        .task(id: nspDir) { await scanSelection() }
        .onChange(of: deps.checking) { _, checking in
            if !checking { Task { metal = await MetalCheck.run(repoPath: settings.repoPath) } }
        }
        .sheet(isPresented: $showFreeSpace) {
            FreeSpaceView(nspDir: URL(fileURLWithPath: nspDir),
                          extraBuildDirs: runner.workDir.map { [$0] } ?? [])
        }
        .toolbar {
            ToolbarItem {
                Button { copyDiagnostics() } label: {
                    Label(diagCopied ? "Copiado" : "Copiar diagnóstico", systemImage: diagCopied ? "checkmark" : "stethoscope")
                }
                .help("Copia un informe para una issue (sin claves ni rutas personales)")
            }
            ToolbarItem {
                Button { showFreeSpace = true } label: { Label("Liberar espacio", systemImage: "externaldrive.badge.minus") }
                    .help("Borrar lo que la siguiente build vuelve a generar")
                    .disabled(nspDir.isEmpty || runner.isRunning)
            }
            ToolbarItem {
                Button { openWindow(id: "deps") } label: {
                    Label("Dependencias", systemImage: deps.missingAny ? "shippingbox.and.arrow.backward.fill" : "shippingbox")
                }
                .help("Comprobar e instalar dependencias")
            }
        }
    }

    // MARK: - Configuración

    private var setupPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                environmentWarnings

                section(1, "Juego") {
                    dropZone
                    fileList
                    cloudWarning
                }

                section(2, "Claves (prod.keys)") {
                    HStack {
                        Text(keysPath.isEmpty ? "Sin elegir (solo vale para un dump)" : keysPath)
                            .font(.callout.monospaced())
                            .foregroundStyle(keysPath.isEmpty ? .secondary : .primary)
                            .lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button("Elegir…") {
                            if let u = choose(mode: .file, start: keysPath.isEmpty ? settings.keysPath : keysPath, prompt: "prod.keys") {
                                keysPath = u.path
                            }
                        }
                    }
                    keyStatus
                }

                section(3, "Qué crear") {
                    Picker("", selection: $platform) {
                        ForEach(Platform.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                metalSection

                DisclosureGroup(isExpanded: $showOptions) {
                    optionsForm.padding(.top, 6)
                } label: { StepHeader(number: 4, title: "Opciones") }

                buildButtons
            }
            .padding(20)
        }
    }

    @ViewBuilder private var environmentWarnings: some View {
        let blocking = deps.blocking(for: platform)
        if !blocking.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Faltan dependencias: " + blocking.map(\.title).joined(separator: ", "), systemImage: "shippingbox.fill")
                Button("Instalar dependencias…") { openWindow(id: "deps") }
            }
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: .rect(cornerRadius: 8))
        }
        if !settings.pythonOK || !settings.scriptOK {
            VStack(alignment: .leading, spacing: 6) {
                if !settings.pythonOK {
                    Label("No encuentro el Python del venv: \(settings.pythonPath) (¿NAS montado?)", systemImage: "exclamationmark.triangle.fill")
                }
                if !settings.scriptOK {
                    Label("No encuentro scripts/build_ipa_from_nsp.py en \(settings.repoPath)", systemImage: "exclamationmark.triangle.fill")
                }
                Button("Abrir Ajustes…") { openSettings() }
            }
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: nspDir.isEmpty ? "folder.badge.plus" : "folder.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            if nspDir.isEmpty {
                Text("Arrastra aquí la carpeta del juego, o los NSP / NSZ / XCI sueltos (y prod.keys)")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else {
                Text(URL(fileURLWithPath: nspDir).lastPathComponent).font(.headline).lineLimit(1)
                Text(nspDir).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            Button(nspDir.isEmpty ? "Elegir carpeta…" : "Cambiar…") {
                let start = nspDir.isEmpty ? settings.defaultBrowseDir : nspDir
                if let u = choose(mode: .folder, start: start, prompt: "Carpeta con los NSP del juego") { setNSP(u) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary.opacity(0.5))
        )
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { dropTargeted = $0 }
    }

    /// Los archivos del juego elegido, por papel. En una carpeta hecha con enlaces (archivos sueltos) se pueden quitar.
    @ViewBuilder private var fileList: some View {
        let staged = !nspDir.isEmpty && GameStaging.isStaged(URL(fileURLWithPath: nspDir))
        if let sel = selection, !(sel.isEmpty && sel.ignored.isEmpty) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sel.files, id: \.url) { f in
                    HStack(spacing: 6) {
                        Text(f.label).font(.caption.bold())
                            .foregroundStyle(f.role == .unknown ? .orange : .secondary)
                            .frame(width: 92, alignment: .leading)
                        Text(f.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if staged {
                            Button { removeFile(f) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .help("Quitar de la build")
                        }
                    }
                }
                if sel.base == nil, !sel.isEmpty {
                    Label("Falta el juego base", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(sel.ignored, id: \.url) { f in
                    Label("De otro juego, no entra: \(f.url.lastPathComponent)", systemImage: "minus.circle")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if staged {
                    Text("Enlaces en ~/NX Build/\(URL(fileURLWithPath: nspDir).lastPathComponent): los originales no se mueven.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        if let m = dropMessage {
            Label(m, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
    }

    /// Una carpeta sola = elegirla. Archivos (y carpetas mezcladas) = se reparten por title ID en base, update y DLC
    /// y se enlazan en ~/NX Build/<juego>. Un prod.keys soltado se usa como claves.
    private func handleDrop(_ urls: [URL]) -> Bool {
        dropMessage = nil
        let fm = FileManager.default
        func isDir(_ u: URL) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue }
        if let k = urls.last(where: { $0.pathExtension.lowercased() == "keys" }) { keysPath = k.path }
        let folders = urls.filter(isDir)
        var games = urls.filter(GameFile.isGameFile)
        if folders.count == 1, games.isEmpty { setNSP(folders[0]); return true }
        for d in folders {
            games += ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter(GameFile.isGameFile)
        }
        guard !games.isEmpty else { return urls.contains { $0.pathExtension.lowercased() == "keys" } }
        let current = selection ?? GameSelection()
        let found = games
        Task {
            let new = await Task.detached { found.map { GameFile.classify($0) } }.value
            var sel = current
            // Un juego base de otro juego empieza una selección nueva.
            if let b = new.first(where: { $0.role == .base }), let app = sel.appID, b.appID != app { sel = GameSelection() }
            sel.add(new)
            applySelection(sel)
        }
        return true
    }

    private func removeFile(_ f: GameFile) {
        guard var sel = selection else { return }
        sel.remove(f)
        sel.ignored = []
        applySelection(sel)
    }

    private func applySelection(_ sel: GameSelection) {
        let ignored = sel.ignored
        guard !sel.isEmpty else {
            selection = nil; nspDir = ""
            if !ignored.isEmpty { dropMessage = "Ninguno de los archivos es del mismo juego" }
            return
        }
        do {
            let dir = try GameStaging.stage(sel)
            setNSP(dir)
            selection = sel
        } catch {
            dropMessage = "No se pudo preparar la carpeta: \(error.localizedDescription)"
        }
    }

    private func scanSelection() async {
        guard !nspDir.isEmpty else { selection = nil; return }
        let dir = URL(fileURLWithPath: nspDir)
        let keepIgnored = selection?.ignored ?? []
        var s = await Task.detached { GameStaging.scan(dir) }.value
        guard !Task.isCancelled else { return }
        if GameStaging.isStaged(dir) { s.ignored = keepIgnored }
        selection = s
    }

    @ViewBuilder private var keyStatus: some View {
        if keyChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Comprobando las claves con el juego…")
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if let k = keyCheck {
            Label(k.message, systemImage: k.isProblem ? "xmark.circle.fill" : (k.isOK ? "checkmark.circle.fill" : "info.circle"))
                .font(.caption)
                .foregroundStyle(k.isProblem ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Lee las cabeceras de los NCA con las claves elegidas (unos KB por archivo) fuera del hilo principal.
    private func runKeyCheck() async {
        keyCheck = nil
        guard !nspDir.isEmpty, !keysPath.isEmpty else { return }
        let folder = URL(fileURLWithPath: nspDir), keys = URL(fileURLWithPath: keysPath)
        keyChecking = true
        let r = await Task.detached { KeyCheck.run(folder: folder, keysFile: keys) }.value
        if !Task.isCancelled { keyCheck = r }
        keyChecking = false
    }

    private func setNSP(_ u: URL) {
        nspDir = u.path
        settings.lastNSPDir = u.path
    }

    @ViewBuilder private var metalSection: some View {
        if let metal, !metal.matches {
            VStack(alignment: .leading, spacing: 6) {
                Label("Compilador Metal distinto del probado", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.bold()).foregroundStyle(.orange)
                Text("Este Mac: \(metal.local ?? "desconocido")\nProbado: \(metal.locked ?? "desconocido")\nLos shaders NVN pueden salir corruptos (issue #242).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Seguir igualmente (--allow-other-metal)", isOn: $options.allowOtherMetal)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: .rect(cornerRadius: 8))
        }
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Idioma (ja, es, fr… vacío = inglés)", text: $options.language)
            TextField("Nombre de la app (vacío = el del NSP)", text: $options.appName)
            if platform == .ios {
                Toggle("RomFS aparte (IPA pequeña, push_romfs.sh)", isOn: $options.romfsSeparate)
                Toggle("Mostrar FPS", isOn: $options.showFPS)
            }
            Toggle("Movimiento / giroscopio", isOn: $options.motion)
            Toggle("Conservar archivos extraídos", isOn: $options.keepExtracted)
            Toggle("Permitir NSP dañado", isOn: $options.allowDamaged)
            Toggle("Permitir regresiones de shaders", isOn: $options.allowShaderRegressions)
            TextField("Argumentos extra", text: $options.extraArgs)
                .font(.callout.monospaced())
        }
        .textFieldStyle(.roundedBorder)
    }

    /// Reúne lo que se ve en la app y deja que Diagnostics complete el resto (git, Xcode, Metal…) fuera del hilo principal.
    private func copyDiagnostics() {
        let phase: String = switch runner.phase {
        case .idle: "no build in this session"
        case .running: "running"
        case .done: "finished"
        case .cancelled: "cancelled"
        case .failed(let c): "failed (exit \(c))"
        }
        let raw = runner.log.map { $0.kind == .error ? "[RED] " + $0.text : $0.text }
        let input = Diagnostics.Input(
            repoPath: settings.repoPath, pythonPath: settings.pythonPath,
            deps: DepID.allCases.map { id in
                let st = deps.state(id)
                return (id.title, "\(st.state)", st.detail)
            },
            game: nspDir.isEmpty ? nil : nspDir,
            gameFiles: selection?.files.map { "\($0.label): \($0.url.lastPathComponent)" } ?? [],
            keyCheck: keyCheck?.message,
            platform: platform.rawValue, phase: phase,
            failure: runner.failure.map { "\($0.kind.rawValue) — \($0.title)" },
            command: raw.first { $0.hasPrefix("$ ") }.map { String($0.dropFirst(2)) },
            logTail: Array(raw.filter { !$0.hasPrefix("$ ") }.suffix(50)))
        Task {
            let text = await Task.detached { Diagnostics.report(input) }.value
            Diagnostics.copyToPasteboard(text)
            diagCopied = true
            try? await Task.sleep(for: .seconds(2))
            diagCopied = false
        }
    }

    private func startBuild() {
        let dir = URL(fileURLWithPath: nspDir)
        var opts = options
        if cloud != nil, buildLocally, opts.workDir.isEmpty {
            opts.workDir = CloudFolder.localWorkDir(for: dir).path
        }
        runner.start(settings: settings, nspDir: dir,
                     keys: keysPath.isEmpty ? nil : URL(fileURLWithPath: keysPath),
                     platform: platform, options: opts)
    }

    /// La carpeta del juego está en la nube: codesign fallará al final. Por defecto se construye en ~/NX Build.
    @ViewBuilder private var cloudWarning: some View {
        if let c = cloud {
            VStack(alignment: .leading, spacing: 6) {
                Label("Carpeta en \(c.service)", systemImage: "icloud.fill")
                    .font(.callout.bold()).foregroundStyle(.orange)
                Text("La nube añade atributos a los archivos y codesign los rechaza: la build fallaría en el último paso.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $buildLocally) {
                    Text("Construir en ~/NX Build/\(URL(fileURLWithPath: nspDir).lastPathComponent)")
                }
                .font(.callout)
                if !c.notDownloaded.isEmpty {
                    Label("Sin descargar: \(c.notDownloaded.joined(separator: ", ")). Se descargarán al leerlos (lento); mejor «Descargar ahora» en Finder antes.",
                          systemImage: "icloud.and.arrow.down")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: .rect(cornerRadius: 8))
        }
    }

    private func runCloudCheck() async {
        guard !nspDir.isEmpty else { cloud = nil; return }
        let dir = URL(fileURLWithPath: nspDir)
        let c = await Task.detached { CloudFolder.check(dir) }.value
        guard !Task.isCancelled else { return }
        cloud = c
        buildLocally = c != nil
    }

    private func failureCard(_ f: BuildFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(f.title, systemImage: f.kind == .unknown ? "questionmark.diamond.fill" : "exclamationmark.octagon.fill")
                .font(.headline).foregroundStyle(.red)
            Text(f.next).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let e = f.evidence {
                Text(e).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(4).textSelection(.enabled)
            }
            HStack {
                ForEach(Array(f.actions.enumerated()), id: \.offset) { _, a in
                    switch a {
                    case .openDependencies:
                        Button("Abrir Dependencias") { openWindow(id: "deps") }
                    case .openSettings:
                        Button("Abrir Ajustes") { openSettings() }
                    case .retry(let flag):
                        Button("Construir igualmente (\(flag))") {
                            switch flag {
                            case "--allow-other-metal": options.allowOtherMetal = true
                            case "--allow-shader-regressions": options.allowShaderRegressions = true
                            case "--allow-damaged": options.allowDamaged = true
                            default: break
                            }
                            startBuild()
                        }
                        .disabled(nspDir.isEmpty)
                    }
                }
                if let log = f.logFile {
                    Button("Abrir log del error") { NSWorkspace.shared.open(log) }
                }
                Button(diagCopied ? "Copiado ✓" : "Copiar diagnóstico") { copyDiagnostics() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: .rect(cornerRadius: 8))
    }

    private var canBuild: Bool {
        !nspDir.isEmpty && settings.pythonOK && settings.scriptOK && !runner.isRunning
            && (metal?.matches ?? true || options.allowOtherMetal)
    }

    private var buildButtons: some View {
        HStack {
            if runner.isRunning {
                Button(role: .destructive) { runner.cancel() } label: {
                    Label("Cancelar", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                Button {
                    startBuild()
                } label: {
                    Label("Construir \(platform == .macApp ? "app" : "IPA")", systemImage: "hammer.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canBuild)
            }
        }
    }

    private func section<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(number: n, title: title)
            content()
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 1) }
    }

    // MARK: - Progreso

    private var progressPane: some View {
        VStack(spacing: 0) {
            statusHeader
                .padding(16)
            Divider()
            if case .failed = runner.phase, let f = runner.failure {
                failureCard(f)
                    .padding(16)
                Divider()
            }
            if !runner.stages.isEmpty {
                stageList
                    .frame(minHeight: 140, maxHeight: 260)
                Divider()
            }
            LogView(lines: runner.log)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusTitle
                Spacer()
                if let start = runner.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(hms((runner.finishedAt ?? ctx.date).timeIntervalSince(start)))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if runner.isRunning, let st = runner.stages.last {
                HStack(alignment: .firstTextBaseline) {
                    Text(st.name).font(.title2.weight(.medium)).foregroundStyle(Color.egluu)
                    Text("etapa \(st.id) de \(max(runner.totalStages, st.id))" + (st.step.isEmpty ? "" : " · \(st.step)"))
                        .font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let f = runner.current.frac {
                        Text(String(format: "%.0f%%", f * 100)).font(.callout.monospaced().bold())
                    }
                }
                if let f = runner.current.frac {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text(countText(runner.current))
                    Spacer()
                    if let eta = runner.current.eta { Text("quedan ~\(hms(eta))") }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                NoteCallout(text: "Puedes cerrar esta ventana: la build sigue y te aviso al terminar.")
            }
            if !runner.isRunning, runner.phase != .idle, let dir = runner.outputDir {
                HStack {
                    Button("Mostrar en Finder") { NSWorkspace.shared.open(dir) }
                    if let logs = runner.workDir.map({ $0.appendingPathComponent("logs") }) ?? runner.lastNSPDir.flatMap(logsDir) {
                        Button("Abrir logs") { NSWorkspace.shared.open(logs) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var statusTitle: some View {
        switch runner.phase {
        case .idle: Label("Listo para construir", systemImage: "shippingbox").font(.title3.bold())
        case .running: Label("Construyendo…", systemImage: "gearshape.2").font(.title3.bold())
        case .done: Label("Hecho", systemImage: "checkmark.seal.fill").font(.title3.bold()).foregroundStyle(.green)
        case .cancelled: Label("Cancelado", systemImage: "xmark.circle").font(.title3.bold()).foregroundStyle(.secondary)
        case .failed(let c): Label("Falló (código \(c))", systemImage: "xmark.octagon.fill").font(.title3.bold()).foregroundStyle(.red)
        }
    }

    private var stageList: some View {
        ScrollViewReader { proxy in
            List(runner.stages) { st in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%02d", st.id))
                        .font(.system(.callout, design: .monospaced).bold()).foregroundStyle(Color.egluuText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(st.name).font(.system(.callout, design: .monospaced))
                            .fontWeight(st.state == .running ? .bold : .regular)
                        if !st.summary.isEmpty {
                            Text(st.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    if let e = st.elapsed { Text(hms(e)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    switch st.state {
                    case .running: StatusTag(text: "En curso", color: .egluuText)
                    case .ok: StatusTag(text: "Hecho", color: .green)
                    case .failed: StatusTag(text: "Error", color: .red)
                    }
                }
                .id(st.id)
            }
            .onChange(of: runner.stages.count) { _, _ in
                if let last = runner.stages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func logsDir(_ nsp: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: nsp, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.lastPathComponent.hasSuffix("_build") }?.appendingPathComponent("logs")
    }
}

struct LogView: View {
    let lines: [LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { l in
                        Text(l.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(l.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(l.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(_ k: LogLine.Kind) -> Color {
        switch k {
        case .info: .primary
        case .note: .secondary
        case .error: .red
        case .stderr: .orange
        }
    }
}

func hms(_ t: Double) -> String {
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

func countText(_ c: CurrentProgress) -> String {
    guard let done = c.done else { return c.note }
    func fmt(_ v: Double) -> String {
        c.unit == "B" ? ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
                      : v.formatted(.number.precision(.fractionLength(0)))
    }
    var s = fmt(done)
    if let t = c.total { s += " / " + (c.est ? "~" : "") + fmt(t) }
    if !c.unit.isEmpty && c.unit != "B" { s += " " + c.unit }
    if let f = c.frac { s += String(format: "  %.0f%%", f * 100) }
    if !c.note.isEmpty { s += "  " + c.note }
    return s
}

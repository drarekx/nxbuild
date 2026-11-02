import SwiftUI
import AppKit

/// Estado de las partidas en la nube de un juego, para la tarjeta y el panel.
struct CloudStatus {
    let folder: String?
    let service: String?

    init(_ g: LibraryGame) {
        folder = CloudSaves(bundleID: g.bundleID, titleID: g.titleID).folder
        service = folder.flatMap { CloudFolder.service(of: $0, home: NSHomeDirectory()) }
    }

    var tag: String { folder == nil ? "Nube desactivada" : service == nil ? "Solo este Mac" : "En la nube" }
    var color: Color { folder == nil ? .secondary : service == nil ? .orange : .egluuText }
}

/// Biblioteca primero: rejilla de juegos y, a la derecha, el panel del juego elegido.
struct LibraryView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Binding var showBuild: Bool
    @State private var selected: String?
    @State private var search = ""
    @State private var optionsFor: LibraryGame?
    @State private var cloudFor: LibraryGame?
    @State private var error: String?
    @State private var refreshTick = 0   // repinta estados tras cerrar una hoja
    @State private var allowFor: LibraryGame?   // pide permiso para quitar la marca de cuarentena y jugar
    @State private var copyOffer: (game: LibraryGame, why: String, protected: Bool)?   // no se pudo quitar: ofrecer copia limpia
    @State private var busy: Busy?               // quitando la marca o copiando: ventana de progreso encima
    @State private var work: Task<Void, Never>?
    private static let appsFolder = NSHomeDirectory() + "/Applications"

    private var shown: [LibraryGame] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return library.games }
        return library.games.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.titleID.localizedCaseInsensitiveContains(q) }
    }
    private var current: LibraryGame? {
        library.games.first { $0.id == selected } ?? shown.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header.padding(.horizontal, 24).padding(.vertical, 16)
                Divider()
                if library.games.isEmpty {
                    ContentUnavailableView {
                        Label(library.scanning ? "Buscando juegos…" : "Sin juegos", systemImage: "gamecontroller")
                    } description: {
                        Text("Construye un juego como «App para Mac» o añade la carpeta donde guardas tus apps de juego.")
                    } actions: {
                        Button("Nueva build") { showBuild = true }.buttonStyle(.borderedProminent)
                        Button("Añadir carpeta…") { addFolder() }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
                            ForEach(shown) { g in card(g) }
                        }
                        .padding(24)
                    }
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity)
            if let g = current {
                Divider()
                detail(g)
                    .frame(width: 340)
                    .id("\(g.id)-\(refreshTick)")
            }
        }
        .task { await library.refresh() }
        .sheet(item: $optionsFor, onDismiss: { refreshTick += 1 }) { g in LaunchOptionsView(game: g) }
        .sheet(item: $cloudFor, onDismiss: { refreshTick += 1 }) { g in CloudSavesView(game: g) }
        .sheet(isPresented: .constant(busy != nil)) {
            if let b = busy { BusySheet(busy: b) { work?.cancel() } }
        }
        .alert("Este juego viene de otro Mac", isPresented: .constant(allowFor != nil), presenting: allowFor) { g in
            Button("Permitir y jugar") { allowFor = nil; allow(g, thenPlay: true) }
            Button("Cancelar", role: .cancel) { allowFor = nil }
        } message: { _ in
            Text("macOS lo ha marcado como descargado y, como no está notarizado por Apple, no dejará abrirlo. Permitirlo quita esa marca de esta copia (lo mismo que «Abrir igualmente» en Privacidad y seguridad). Hazlo solo con juegos que hayas construido tú.")
        }
        .alert("No se pudo quitar la marca", isPresented: .constant(copyOffer != nil), presenting: copyOffer) { o in
            Button("Hacer una copia limpia") { copyOffer = nil; cleanCopy(o.game) }
            if o.protected {
                Button("Dar permiso en Ajustes…") {
                    copyOffer = nil
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
                }
            }
            Button("Cancelar", role: .cancel) { copyOffer = nil }
        } message: { o in
            Text(o.protected
                 ? "\(o.why)\n\nRecomendado: copia limpia. NX Build copia el juego a ~/Applications sin la marca (ocupa lo mismo; luego puedes borrar el original). Las partidas no cambian: van por el title ID.\n\nO activa NX Build en Ajustes › Privacidad y seguridad › Gestión de apps, vuelve a abrir NX Build y pulsa Permitir abrir."
                 : "\(o.why)\n\nNX Build puede copiar el juego a ~/Applications sin la marca y a tu nombre (ocupa lo mismo que el original; luego puedes borrar el original). Las partidas no cambian: van por el title ID.")
        }
        .alert("No se pudo abrir el juego", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Tus juegos").font(.title2.weight(.medium)).foregroundStyle(Color.egluu)
                Text("\(library.games.count) juego\(library.games.count == 1 ? "" : "s") · \(library.folders.count) carpeta\(library.folders.count == 1 ? "" : "s")")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Buscar juego", text: $search)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            Menu {
                ForEach(library.folders, id: \.self) { f in
                    Menu(f.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        Button("Mostrar en Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: f)) }
                        Button("Quitar de la biblioteca") { library.removeFolder(f); Task { await library.refresh() } }
                    }
                }
                Divider()
                Button("Añadir carpeta…") { addFolder() }
                Button("Volver a buscar") { Task { await library.refresh() } }
            } label: { Label("Carpetas", systemImage: "folder") }
            .fixedSize()
            Button { showBuild = true } label: { Label("Nueva build", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
        }
    }

    private func addFolder() {
        if let u = choose(mode: .folder, start: GameStaging.root.path, prompt: "Carpeta con apps de juego") {
            library.addFolder(u.path)
            Task { await library.refresh() }
        }
    }

    private func play(_ g: LibraryGame) {
        if g.isQuarantined { allowFor = g; return }
        Task {
            do { try await library.play(g, skipWindow: settings.skipGameWindow) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Quita la marca de cuarentena (Quarantine.remove) y, si se pide, abre el juego.
    private func allow(_ g: LibraryGame, thenPlay: Bool) {
        guard busy == nil else { return }
        selected = g.id
        busy = Busy(game: g, title: "Permitiendo «\(g.name)»", progress: .init(step: "Empezando"))
        work = Task {
            defer { busy = nil; work = nil }
            do {
                try await Quarantine.remove(from: g.path) { p in
                    Task { @MainActor in if busy?.game.id == g.id { busy?.progress = p } }
                }
                refreshTick += 1
                if thenPlay { busy = nil; play(g) }
            } catch is CancellationError {
            } catch Quarantine.Failure.cancelled {
                // canceló aquí o en la contraseña: nada que avisar
            } catch let e as Quarantine.Failure {
                if case .protectedByMacOS = e { copyOffer = (g, e.localizedDescription, true) }
                else { copyOffer = (g, e.localizedDescription, false) }
            } catch {
                copyOffer = (g, error.localizedDescription, false)
            }
        }
    }

    /// Copia limpia en ~/Applications, la añade a la biblioteca y la selecciona.
    private func cleanCopy(_ g: LibraryGame) {
        guard busy == nil else { return }
        selected = g.id
        busy = Busy(game: g, title: "Copia limpia de «\(g.name)»", progress: .init(step: "Empezando"))
        work = Task {
            defer { busy = nil; work = nil }
            do {
                let dest = try await Quarantine.cleanCopy(of: g.path, into: Self.appsFolder) { p in
                    Task { @MainActor in if busy?.game.id == g.id { busy?.progress = p } }
                }
                if !library.folders.contains(Self.appsFolder) { library.addFolder(Self.appsFolder) }
                await library.refresh()
                selected = dest
                refreshTick += 1
            } catch is CancellationError {
            } catch Quarantine.Failure.cancelled {
            } catch { self.error = error.localizedDescription }
        }
    }

    private func card(_ g: LibraryGame) -> some View {
        let isSel = current?.id == g.id
        let cloud = CloudStatus(g)
        return Button { selected = g.id } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(isSel ? Color.egluuSoft : Color(nsColor: .controlBackgroundColor))
                    HStack(alignment: .bottom) {
                        Text(g.name).font(.title3.weight(.semibold)).lineLimit(3).multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(nsImage: NSWorkspace.shared.icon(forFile: g.path)).resizable().frame(width: 40, height: 40)
                    }
                    .padding(12)
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.titleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if busy?.game.id == g.id {
                        StatusTag(text: "Trabajando…", color: .egluuText)
                    } else if g.isQuarantined {
                        StatusTag(text: "Bloqueado por macOS", color: .orange)
                    } else {
                        StatusTag(text: cloud.tag, color: cloud.color)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .id(refreshTick)
            }
            .contentShape(Rectangle())
            .overlay { Rectangle().strokeBorder(isSel ? Color.egluu : Color(nsColor: .separatorColor), lineWidth: isSel ? 2 : 1) }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { play(g) })
        .help(g.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + " · doble clic para jugar")
        .contextMenu {
            Button("Jugar") { play(g) }
            Button("Opciones de lanzamiento…") { optionsFor = g }.disabled(!g.hasLaunchSettings)
            Button("Partidas en la nube…") { cloudFor = g }
            if g.isQuarantined { Button("Permitir abrir") { allow(g, thenPlay: false) }.disabled(busy != nil) }
            Divider()
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([g.url]) }
        }
    }

    private func detail(_ g: LibraryGame) -> some View {
        let cloud = CloudStatus(g)
        let changed = g.hasLaunchSettings
            ? SavedChoices(bundleID: g.bundleID).changedCount(LaunchSettingsFile.load(app: g.url)?.settings ?? []) : 0
        let dlc = g.dlcCount
        let backups = URL(fileURLWithPath: g.saveURL.path + "-backups")
        let fm = FileManager.default
        let quarantined = g.isQuarantined
        let needsSystem = g.requiredSystemIfNewer
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(g.name).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text([g.titleID, g.version.isEmpty ? nil : "v\(g.version)",
                          g.builtAt.map { "construido " + $0.formatted(date: .abbreviated, time: .omitted) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button { play(g) } label: {
                        Label("Jugar", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                    Button { optionsFor = g } label: { Image(systemName: "slider.horizontal.3").frame(minHeight: 30) }
                        .controlSize(.large)
                        .help(g.hasLaunchSettings ? "Opciones de lanzamiento" : "Esta app no trae launcher.json: vuelve a construirla")
                        .disabled(!g.hasLaunchSettings)
                        .accessibilityLabel("Opciones de lanzamiento")
                }
                if quarantined {
                    VStack(alignment: .leading, spacing: 8) {
                        NoteCallout(text: "Copiado de otro Mac: macOS lo ha marcado como descargado y no deja abrirlo porque no está notarizado por Apple.")
                        Button("Permitir abrir") { allow(g, thenPlay: false) }
                            .disabled(busy != nil)
                            .help("Quita la marca com.apple.quarantine de esta copia")
                    }
                }
                if let v = needsSystem {
                    let os = ProcessInfo.processInfo.operatingSystemVersion
                    Label("Necesita macOS \(v) o posterior; este Mac tiene \(os.majorVersion).\(os.minorVersion).\(os.patchVersion). Actualiza macOS o constrúyelo con una versión de nxnative que admita la tuya.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        StatusTag(text: "Partidas")
                        VStack(alignment: .leading, spacing: 3) {
                            if let f = cloud.folder {
                                Text(cloud.service.map { "Sincronizadas por \($0)" } ?? "En una carpeta que no está en la nube")
                                    .foregroundStyle(cloud.service == nil ? Color.orange : Color.primary)
                                Text(f.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                                Button("Cambiar…") { cloudFor = g }.buttonStyle(.link)
                            } else {
                                Text("Solo en este Mac")
                                Button("Sincronizar en la nube…") { cloudFor = g }.buttonStyle(.link)
                            }
                        }
                    }
                    GridRow {
                        StatusTag(text: "Opciones")
                        Text(!g.hasLaunchSettings ? "Esta build no trae opciones" : changed == 0 ? "Las probadas" : "\(changed) cambiada\(changed == 1 ? "" : "s")")
                    }
                    GridRow {
                        StatusTag(text: "DLC")
                        Text(dlc == 0 ? "Ninguno dentro de la app" : "\(dlc) dentro de la app")
                    }
                    GridRow {
                        StatusTag(text: "Archivos")
                        VStack(alignment: .leading, spacing: 3) {
                            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([g.url]) }
                            Button("Log") { NSWorkspace.shared.open(g.logURL) }.disabled(!fm.fileExists(atPath: g.logURL.path))
                            Button("Carpeta de partidas") { NSWorkspace.shared.open(g.saveURL) }.disabled(!fm.fileExists(atPath: g.saveURL.path))
                            if fm.fileExists(atPath: backups.path) {
                                Button("Copias de seguridad") { NSWorkspace.shared.open(backups) }
                            }
                            Button("Copiar title ID") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(g.titleID, forType: .string)
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.callout)
                if cloud.service != nil {
                    NoteCallout(text: "Cierra el juego aquí y espera unos segundos antes de abrirlo en otro equipo.")
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }
}

/// Las opciones de lanzamiento de un juego, como la ventana de ajustes de la propia app: se guardan al momento en sus
/// preferencias (launcher.<VAR>) y valen también al abrirlo desde Finder.
struct LaunchOptionsView: View {
    let game: LibraryGame
    @Environment(\.dismiss) private var dismiss
    @Environment(GameLibrary.self) private var library
    @Environment(AppSettings.self) private var appSettings

    @State private var settings: [LaunchSetting] = []
    @State private var values: [String: String] = [:]
    @State private var showAdvanced = false

    private var saved: SavedChoices { SavedChoices(bundleID: game.bundleID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.title3.bold())
                Text("Opciones de lanzamiento · se guardan al momento y valen también al abrirlo desde Finder")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            Form {
                ForEach(sections, id: \.self) { sec in
                    let rows = settings.filter { ($0.section ?? "Otros") == sec && $0.isBasic && visible($0) }
                    if !rows.isEmpty {
                        Section(sectionName(sec)) { ForEach(rows) { row($0) } }
                    }
                }
                let advanced = settings.filter { !$0.isBasic && visible($0) }
                if !advanced.isEmpty {
                    Section {
                        DisclosureGroup("Avanzado (\(advanced.count))", isExpanded: $showAdvanced) {
                            ForEach(advanced) { row($0) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Restablecer valores probados") {
                    saved.reset(settings); load()
                }
                .disabled(settings.allSatisfy { values[$0.env].map($0.isDefault) ?? true })
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { try? await library.play(game, skipWindow: appSettings.skipGameWindow); dismiss() }
                } label: { Label("Jugar", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .onAppear(perform: load)
    }

    private var sections: [String] {
        var seen: [String] = []
        for s in settings { let n = s.section ?? "Otros"; if !seen.contains(n) { seen.append(n) } }
        return seen
    }

    private func sectionName(_ s: String) -> String {
        ["Game": "Juego", "Controls": "Controles", "Performance": "Rendimiento"][s] ?? s
    }

    private func load() {
        settings = LaunchSettingsFile.load(app: game.url)?.settings ?? []
        values = Dictionary(uniqueKeysWithValues: settings.map { ($0.env, saved.effective($0)) })
    }

    private func visible(_ s: LaunchSetting) -> Bool {
        guard let n = s.needs, let eq = n.firstIndex(of: "=") else { return true }
        let v = String(n[..<eq]), want = String(n[n.index(after: eq)...])
        guard settings.contains(where: { $0.env == v }) else { return true }
        return values[v] == want
    }

    private func binding(_ s: LaunchSetting) -> Binding<String> {
        Binding(get: { values[s.env] ?? s.defaultValue },
                set: { values[s.env] = $0; saved.set(s, $0) })
    }

    @ViewBuilder private func row(_ s: LaunchSetting) -> some View {
        let changed = !(values[s.env].map(s.isDefault) ?? true)
        VStack(alignment: .leading, spacing: 3) {
            switch s.kind {
            case "choice":
                Picker(selection: binding(s)) {
                    ForEach(s.options ?? [], id: \.self) { o in Text(o.count > 1 ? o[1] : o[0]).tag(o[0]) }
                } label: { rowLabel(s, changed) }
            case "toggle":
                Toggle(isOn: Binding(get: { (values[s.env] ?? s.defaultValue) == s.on },
                                     set: { binding(s).wrappedValue = ($0 ? s.on : s.off) ?? s.defaultValue })) {
                    rowLabel(s, changed)
                }
            case "range":
                let x = Double(values[s.env] ?? s.defaultValue) ?? s.min ?? 0
                LabeledContent {
                    HStack {
                        Slider(value: Binding(get: { x }, set: { binding(s).wrappedValue = s.format($0) }),
                               in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.01)
                        Text(s.format(x)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                } label: { rowLabel(s, changed) }
            default:
                LabeledContent { Text(values[s.env] ?? s.defaultValue) } label: { rowLabel(s, changed) }
            }
            if let n = s.note, !n.isEmpty {
                Text(n).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func rowLabel(_ s: LaunchSetting, _ changed: Bool) -> some View {
        HStack(spacing: 4) {
            Text(s.label)
            if changed { Circle().fill(.tint).frame(width: 6, height: 6).help("Cambiado (el probado es \(s.defaultValue))") }
        }
    }
}

/// Ventana principal: construir y biblioteca.
struct RootView: View {
    @Environment(BuildRunner.self) private var runner
    @Environment(GameLibrary.self) private var library
    @State private var tab = "library"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Biblioteca", systemImage: "square.grid.2x2", value: "library") {
                LibraryView(showBuild: Binding(get: { tab == "build" }, set: { if $0 { tab = "build" } }))
            }
            Tab("Colección", systemImage: "shippingbox", value: "collection") {
                CollectionView(showBuild: Binding(get: { tab == "build" }, set: { if $0 { tab = "build" } }))
            }
            Tab(runner.isRunning ? "Construyendo…" : "Nueva build", systemImage: runner.isRunning ? "gearshape.2" : "hammer", value: "build") {
                ContentView()
            }
        }
        .tint(Color.egluuText)
        .onChange(of: runner.phase) { _, phase in
            // Una app de Mac recién construida entra en la biblioteca: su carpeta se añade y se vuelve a buscar.
            guard phase == .done, let out = runner.outputDir, runner.lastPlatform == .macApp else { return }
            library.addFolder(out.path)
            Task { await library.refresh() }
        }
    }
}

/// Trabajo largo sobre un juego (quitar la marca, copia limpia).
struct Busy {
    var game: LibraryGame
    var title: String
    var progress: Quarantine.Progress
    var started = Date()
}

/// Ventana encima de la biblioteca mientras se trabaja: paso, barra, archivos, archivo en curso, tiempo y Cancelar.
struct BusySheet: View {
    let busy: Busy
    let cancel: () -> Void

    var body: some View {
        let p = busy.progress
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: busy.game.path)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(busy.title).font(.headline)
                    Text(p.step).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let f = p.fraction {
                ProgressView(value: f).tint(Color.egluu)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Color.egluu)
            }
            HStack {
                if p.total > 0 {
                    Text("\(p.done.formatted()) de \(p.total.formatted()) archivos")
                }
                Spacer()
                TimelineView(.periodic(from: busy.started, by: 1)) { ctx in
                    Text(Duration.seconds(ctx.date.timeIntervalSince(busy.started)).formatted(.time(pattern: .minuteSecond)))
                }
            }
            .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(p.current.isEmpty ? " " : p.current)
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }
}

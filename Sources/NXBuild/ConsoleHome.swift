import SwiftUI
import AppKit
import GameController

/// Paleta del panel de consola: fondo carbón, superficies un poco más claras y un acento turquesa.
extension Color {
    static let consoleBG = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1b / 255)
    static let consoleSurface = Color(red: 0x23 / 255, green: 0x27 / 255, blue: 0x31 / 255)
    static let consoleLine = Color(red: 0x26 / 255, green: 0x2a / 255, blue: 0x33 / 255)
    static let consoleText = Color(red: 0xee / 255, green: 0xf1 / 255, blue: 0xf6 / 255)
    static let consoleDim = Color(red: 0x9a / 255, green: 0xa3 / 255, blue: 0xb2 / 255)
    static let consoleAccent = Color(red: 0x2e / 255, green: 0xe6 / 255, blue: 0xc5 / 255)
    static let consoleOnAccent = Color(red: 0x0b / 255, green: 0x1a / 255, blue: 0x17 / 255)
}

/// Mando (GameController): cruceta/stick y botones convertidos en eventos para la pantalla que esté delante.
/// Solo cuenta con NX Build activa: con un juego abierto, el mando es del juego.
@MainActor @Observable
final class Gamepad {
    enum Button: Equatable { case left, right, up, down, a, b, x, y, plus }
    struct Event: Equatable { let button: Button; let id = UUID() }

    static let shared = Gamepad()
    private(set) var event: Event?
    private(set) var name: String?

    private init() {
        let nc = NotificationCenter.default
        for n in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        }
        sync()
        GCController.startWirelessControllerDiscovery {}
    }

    /// Engancha los mandos conectados (volver a poner los manejadores no duplica nada).
    private func sync() {
        let all = GCController.controllers()
        name = all.first.map { $0.vendorName ?? "Mando" }
        all.forEach(attach)
    }

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad else { return }
        func on(_ input: GCControllerButtonInput, _ b: Button) {
            input.pressedChangedHandler = { _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in Gamepad.shared.send(b) }
            }
        }
        on(pad.dpad.left, .left); on(pad.dpad.right, .right); on(pad.dpad.up, .up); on(pad.dpad.down, .down)
        on(pad.leftThumbstick.left, .left); on(pad.leftThumbstick.right, .right)
        on(pad.leftThumbstick.up, .up); on(pad.leftThumbstick.down, .down)
        on(pad.buttonA, .a); on(pad.buttonB, .b); on(pad.buttonX, .x); on(pad.buttonY, .y)
        on(pad.buttonMenu, .plus)
    }

    private func send(_ b: Button) {
        guard NSApp.isActive else { return }
        event = Event(button: b)
    }
}

/// Ventana principal como panel de consola: Inicio (carrusel de juegos y menú) y, encima, Biblioteca, Colección o
/// Nueva build con una barra para volver.
struct RootView: View {
    enum Screen: Equatable { case home, library, collection, build }

    @Environment(BuildRunner.self) private var runner
    @Environment(GameLibrary.self) private var library
    @State private var screen = Screen.home
    @State private var libraryStart: String?
    @State private var playOnOpen = false
    private let pad = Gamepad.shared

    private var buildBinding: Binding<Bool> {
        Binding(get: { screen == .build }, set: { if $0 { screen = .build } })
    }

    var body: some View {
        ZStack {
            Color.consoleBG.ignoresSafeArea()
            switch screen {
            case .home:
                HomeView(open: { screen = $0 }, openLibrary: { id, play in
                    libraryStart = id; playOnOpen = play; screen = .library
                })
                .transition(.opacity)
            case .library:
                ConsolePage(title: "Biblioteca", back: back) {
                    LibraryView(showBuild: buildBinding, startWith: libraryStart, playOnAppear: playOnOpen)
                }
            case .collection:
                ConsolePage(title: "Colección", back: back) { CollectionView(showBuild: buildBinding) }
            case .build:
                ConsolePage(title: runner.isRunning ? "Construyendo…" : "Nueva build", back: back) { ContentView() }
            }
        }
        .animation(.easeOut(duration: 0.18), value: screen)
        .preferredColorScheme(.dark)
        .tint(Color.consoleAccent)
        .onChange(of: pad.event) { _, e in
            if e?.button == .b, screen != .home { back() }
        }
        .onChange(of: runner.phase) { _, phase in
            // Una app de Mac recién construida entra en la biblioteca: su carpeta se añade y se vuelve a buscar.
            guard phase == .done, let out = runner.outputDir, runner.lastPlatform == .macApp else { return }
            library.addFolder(out.path)
            Task { await library.refresh() }
        }
    }

    private func back() { libraryStart = nil; playOnOpen = false; screen = .home }
}

/// Pantalla secundaria: barra superior con «Inicio» (Esc o B del mando) y título, y su contenido debajo.
struct ConsolePage<Content: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(action: back) {
                    Label("Inicio", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(Color.consoleSurface, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Volver al inicio (Esc o B del mando)")
                Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                ConsoleClock(size: 17)
            }
            .foregroundStyle(Color.consoleText)
            .padding(.leading, 84).padding(.trailing, 24).frame(height: 52)
            .background(Color.consoleBG)
            Rectangle().fill(Color.consoleLine).frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ConsoleClock: View {
    var size: CGFloat = 24
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            Text(ctx.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
        }
    }
}

/// Inicio: perfil y estado arriba, carrusel de juegos (el elegido grande), datos del juego, menú de botones redondos
/// y barra con los atajos del mando.
struct HomeView: View {
    let open: (RootView.Screen) -> Void
    let openLibrary: (_ select: String?, _ play: Bool) -> Void

    @Environment(GameLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(BuildRunner.self) private var runner
    @Environment(FileboxDownloads.self) private var downloads
    @Environment(FileboxStore.self) private var store
    @Environment(FileboxUploads.self) private var uploads
    @Environment(\.openSettings) private var openSettings
    @State private var focus = 0
    @State private var optionsFor: LibraryGame?
    @State private var cloudFor: LibraryGame?
    @State private var error: String?
    @State private var sizes: [String: Int64] = [:]
    @State private var free: Int64?
    @FocusState private var keys: Bool
    private let pad = Gamepad.shared

    private var games: [LibraryGame] { library.games }
    private var current: LibraryGame? { games.indices.contains(focus) ? games[focus] : nil }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 56).padding(.top, 36)
            Spacer(minLength: 24)
            carousel
            info.padding(.horizontal, 56).padding(.top, 28).frame(height: 70, alignment: .top)
            Spacer(minLength: 24)
            menu.padding(.bottom, 32)
            footer
        }
        .foregroundStyle(Color.consoleText)
        .focusable().focused($keys).focusEffectDisabled()
        .onAppear { keys = true }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.return) { if let g = current { play(g) }; return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "xXyY+")) { k in
            switch k.characters.lowercased() {
            case "x": if let g = current, g.hasLaunchSettings { optionsFor = g }
            case "y": openLog()
            default: open(.build)
            }
            return .handled
        }
        .onChange(of: pad.event) { _, e in
            switch e?.button {
            case .left: move(-1)
            case .right: move(1)
            case .a: if let g = current { play(g) } else if games.isEmpty { open(.build) }
            case .x: if let g = current, g.hasLaunchSettings { optionsFor = g }
            case .y: openLog()
            case .plus: open(.build)
            case .down: openLibrary(current?.id, false)
            default: break
            }
        }
        .task { await library.refresh(); free = FreeSpace.freeBytes(on: GameStaging.root) ?? FreeSpace.freeBytes(on: URL(fileURLWithPath: NSHomeDirectory())) }
        .task(id: current?.id) { await measure(current) }
        .task {
            // Portadas de Filebox: la colección en caché sirve; se pone al día si hace más de una hora.
            if store.isConfigured, Covers.shared.preferFilebox || !Covers.shared.overrides.isEmpty,
               (store.lastSync ?? .distantPast) < Date().addingTimeInterval(-3600) { await store.refresh() }
        }
        .onChange(of: games.count) { _, n in focus = min(focus, max(0, n - 1)) }
        .sheet(item: $optionsFor) { g in LaunchOptionsView(game: g) }
        .sheet(item: $cloudFor) { g in CloudSavesView(game: g) }
        .alert("No se pudo abrir el juego", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    // MARK: Cabecera

    private var header: some View {
        HStack {
            HStack(spacing: 14) {
                Text(String(NSFullUserName().first ?? "N"))
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.consoleOnAccent)
                    .frame(width: 50, height: 50).background(Color.consoleAccent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSFullUserName().split(separator: " ").first.map(String.init) ?? "Jugador")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text([Host.current().localizedName, Self.chip].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13, design: .rounded)).foregroundStyle(Color.consoleDim)
                }
            }
            Spacer()
            HStack(spacing: 26) {
                let active = downloads.states.values.filter { if case .downloading = $0 { true } else { false } }.count
                if active > 0 {
                    Button { open(.collection) } label: {
                        Label("\(active) descarga\(active == 1 ? "" : "s")", systemImage: "arrow.down.circle")
                    }.buttonStyle(.plain)
                }
                if uploads.activeCount > 0 {
                    Button { openLibrary(uploads.states.first { $0.value.isActive }?.key, false) } label: {
                        let first = uploads.states.values.first { $0.isActive }
                        Label(uploads.activeCount == 1 ? "Filebox: \(first?.short ?? "")"
                                                       : "\(uploads.activeCount) subidas · \(first?.short ?? "")",
                              systemImage: "arrow.up.circle").monospacedDigit()
                    }.buttonStyle(.plain)
                }
                if runner.isRunning {
                    Button { open(.build) } label: { Label("Construyendo", systemImage: "hammer") }.buttonStyle(.plain)
                }
                if let n = pad.name { Label(n, systemImage: "gamecontroller") }
                if let free { Label("\(free.formatted(.byteCount(style: .file))) libres", systemImage: "internaldrive") }
                ConsoleClock(size: 26).foregroundStyle(Color.consoleText)
            }
            .font(.system(size: 16, design: .rounded))
            .foregroundStyle(Color(red: 0xc9 / 255, green: 0xcf / 255, blue: 0xda / 255))
        }
        .padding(.leading, 28)   // deja sitio a los botones de la ventana
    }

    private static let chip: String? = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf).replacingOccurrences(of: "Apple ", with: "")
    }()

    // MARK: Carrusel

    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 22) {
                    if games.isEmpty {
                        emptyTile
                    }
                    ForEach(Array(games.enumerated()), id: \.element.id) { i, g in
                        GameTile(game: g, focused: i == focus, running: library.isRunning(g))
                            .id(g.id)
                            .onTapGesture(count: 2) { focus = i; play(g) }
                            .onTapGesture { focus = i }
                            .contextMenu {
                                Button("Jugar") { play(g) }
                                Button("Opciones de lanzamiento…") { optionsFor = g }.disabled(!g.hasLaunchSettings)
                                Button("Partidas en la nube…") { cloudFor = g }
                                Button("Ver en la biblioteca") { openLibrary(g.id, false) }
                                Button("Subir a Filebox") { uploads.upload(g, store: store); openLibrary(g.id, false) }
                                    .disabled(!store.isConfigured || uploads.state(g)?.isActive == true)
                                Picker("Portada", selection: Binding(get: { Covers.shared.choice(for: g) },
                                                                     set: { Covers.shared.set($0, for: g) })) {
                                    ForEach(Covers.Source.allCases) { Text($0.label).tag($0) }
                                }
                                Divider()
                                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([g.url]) }
                            }
                    }
                    Button { openLibrary(current?.id, false) } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "square.grid.2x2").font(.system(size: 30))
                            Text(games.isEmpty ? "Biblioteca" : "Todos (\(games.count))")
                                .font(.system(size: 15, design: .rounded))
                        }
                        .foregroundStyle(Color.consoleDim)
                        .frame(width: 160, height: 160)
                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(white: 0.24), style: StrokeStyle(lineWidth: 2, dash: [7, 6])))
                        .contentShape(RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 56).padding(.vertical, 16)
            }
            .scrollClipDisabled()
            .onChange(of: focus) { _, i in
                guard games.indices.contains(i) else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(games[i].id, anchor: .center) }
            }
        }
        .frame(height: 360)
    }

    private var emptyTile: some View {
        Button { open(.build) } label: {
            VStack(alignment: .leading) {
                Text("SIN JUEGOS").font(.system(size: 13, weight: .bold, design: .rounded)).tracking(1.5).opacity(0.75)
                Spacer()
                Text("Construye tu primer juego").font(.system(size: 28, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.leading)
                Text("Elige la carpeta del NSP en Nueva build").font(.system(size: 14, design: .rounded)).opacity(0.8)
            }
            .padding(26).frame(width: 300, height: 300, alignment: .leading)
            .foregroundStyle(Color.consoleOnAccent)
            .background(Color.consoleAccent, in: RoundedRectangle(cornerRadius: 26))
        }
        .buttonStyle(.plain)
    }

    // MARK: Datos del juego elegido

    @ViewBuilder private var info: some View {
        if let g = current {
            let cloud = CloudStatus(g)
            HStack(spacing: 30) {
                if !g.version.isEmpty { fact("Versión", g.version) }
                fact("Jugado", lastPlayed(g))
                fact("Ocupa", sizes[g.id].map { $0.formatted(.byteCount(style: .file)) } ?? "…")
                fact("Partidas", cloud.tag.lowercased())
                if g.isQuarantined {
                    Label("Bloqueado por macOS: pulsa Jugar para permitirlo", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                }
                if let v = g.requiredSystemIfNewer {
                    Label("Necesita macOS \(v)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Spacer()
            }
            .font(.system(size: 16, design: .rounded))
            .foregroundStyle(Color.consoleDim)
            .id("\(g.id)-\(optionsFor == nil)-\(cloudFor == nil)")
        }
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k)
            Text(v).fontWeight(.bold).foregroundStyle(Color.consoleText)
        }
    }

    private func lastPlayed(_ g: LibraryGame) -> String {
        guard let d = (try? g.logURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return "nunca" }
        return d.formatted(.relative(presentation: .named))
    }

    private func measure(_ g: LibraryGame?) async {
        guard let g, sizes[g.id] == nil else { return }
        let url = g.url
        let n = await Task.detached(priority: .utility) { FreeSpace.size(of: url) }.value
        sizes[g.id] = n
    }

    // MARK: Menú

    private var menu: some View {
        HStack(alignment: .top, spacing: 30) {
            RoundMenuButton(label: "Biblioteca", icon: "square.grid.2x2", primary: true) { openLibrary(current?.id, false) }
            RoundMenuButton(label: "Colección", icon: "shippingbox") { open(.collection) }
            RoundMenuButton(label: runner.isRunning ? "Construyendo" : "Nueva build",
                            icon: runner.isRunning ? "gearshape.2" : "plus", busy: runner.isRunning) { open(.build) }
            RoundMenuButton(label: "Partidas", icon: "icloud") { if let g = current { cloudFor = g } }
                .disabled(current == nil)
            RoundMenuButton(label: Updater.shared.state == .idle ? "Actualizar" : "Buscando…",
                            icon: "arrow.triangle.2.circlepath") {
                Task { await Updater.shared.check(userInitiated: true) }
            }
            .disabled(Updater.shared.state != .idle || !Updater.shared.canUpdate)
            RoundMenuButton(label: "Ajustes", icon: "gearshape") { openSettings() }
        }
    }

    // MARK: Barra de atajos

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.consoleLine).frame(height: 1)
            HStack {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 30, height: 30)
                    Text("NX ").fontWeight(.heavy) + Text("Build").fontWeight(.heavy).foregroundStyle(Color.consoleAccent)
                    Text(Updater.currentVersion).foregroundStyle(Color.consoleDim)
                }
                Spacer()
                HStack(spacing: 24) {
                    hint("A", "Jugar") { if let g = current { play(g) } }.disabled(current == nil)
                    hint("X", "Opciones") { if let g = current { optionsFor = g } }.disabled(current?.hasLaunchSettings != true)
                    hint("Y", "Log") { openLog() }
                        .disabled(current.map { !FileManager.default.fileExists(atPath: $0.logURL.path) } ?? true)
                    hint("+", "Nueva build") { open(.build) }
                }
            }
            .font(.system(size: 15, design: .rounded))
            .padding(.horizontal, 56).frame(height: 58)
        }
    }

    private func hint(_ key: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(key).font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.consoleBG)
                    .frame(width: 26, height: 26).background(Color.consoleText, in: Circle())
                Text(label).foregroundStyle(Color(red: 0xc9 / 255, green: 0xcf / 255, blue: 0xda / 255))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Acciones

    private func move(_ d: Int) {
        guard !games.isEmpty else { return }
        focus = min(max(0, focus + d), games.count - 1)
    }

    private func play(_ g: LibraryGame) {
        // Bloqueado por la cuarentena: la biblioteca sabe permitirlo (pide permiso, copia limpia…).
        if g.isQuarantined { openLibrary(g.id, true); return }
        Task {
            do { try await library.play(g, skipWindow: settings.skipGameWindow) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func openLog() {
        guard let g = current, FileManager.default.fileExists(atPath: g.logURL.path) else { return }
        NSWorkspace.shared.open(g.logURL)
    }
}

/// Portada de un juego a sangre: la de Filebox (mismo title ID) o el icono del NSP (AppIcon.icns), según Covers;
/// el elegido, grande y con anillo de foco.
struct GameTile: View {
    let game: LibraryGame
    let focused: Bool
    let running: Bool
    @Environment(FileboxStore.self) private var store
    @State private var remote: NSImage?
    private let covers = Covers.shared

    var body: some View {
        let size: CGFloat = focused ? 290 : 160
        let radius: CGFloat = focused ? 26 : 20
        VStack(spacing: 12) {
            if focused {
                Text(game.name)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.consoleAccent)
                    .lineLimit(1)
                    .frame(width: 420)
                    .transition(.opacity)
            }
            ZStack(alignment: .bottomLeading) {
                cover
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    if running { badge("ABIERTO", Color.consoleAccent, Color.consoleOnAccent) }
                    else if game.isQuarantined { badge("BLOQUEADO", .orange, .black) }
                    if !focused || image == nil {
                        Text(game.name)
                            .font(.system(size: focused ? 26 : 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white).lineLimit(3).multilineTextAlignment(.leading)
                    }
                }
                .padding(focused ? 22 : 14)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: radius + 7).strokeBorder(Color.consoleAccent, lineWidth: 5).padding(-11)
                }
            }
            .shadow(color: focused ? Color.consoleAccent.opacity(0.18) : .clear, radius: 24)
            .contentShape(RoundedRectangle(cornerRadius: radius))
        }
        .animation(.spring(duration: 0.25), value: focused)
        .task(id: remoteKey) {
            remote = nil
            guard let c = fileboxCover else { return }
            remote = await covers.remote(c, apiBase: store.baseURL)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(game.name)
        .accessibilityAddTraits(.isButton)
    }

    private var fileboxCover: FBImage? {
        covers.wantsFilebox(game) ? covers.fileboxCover(for: game, in: store) : nil
    }
    private var remoteKey: String { fileboxCover?.url.split(separator: "?").first.map(String.init) ?? "" }
    /// La de Filebox si toca y ya está; si no (o mientras carga, o sin conexión), el icono del juego.
    private var image: NSImage? { (fileboxCover != nil ? remote : nil) ?? covers.gameIcon(game) }

    @ViewBuilder private var cover: some View {
        if let img = image {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(Self.color(for: game.titleID.isEmpty ? game.name : game.titleID))
        }
    }

    private func badge(_ t: String, _ bg: Color, _ fg: Color) -> some View {
        Text(t).font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1)
            .foregroundStyle(fg).padding(.horizontal, 8).padding(.vertical, 4).background(bg, in: Capsule())
    }

    /// Color estable por juego para los que no traen icono.
    static func color(for s: String) -> Color {
        let palette: [(Double, Double, Double)] = [(0x6b, 0x4a, 0x2b), (0x2f, 0x5d, 0x4a), (0xa8, 0x32, 0x3a), (0x2c, 0x3f, 0x73),
                                                   (0x3b, 0x3f, 0x4a), (0x6a, 0x3d, 0x78), (0x2b, 0x5a, 0x6e), (0x6e, 0x5a, 0x1f)]
        let h = s.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        let c = palette[h % palette.count]
        return Color(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255)
    }
}

/// Botón redondo del menú de inicio con su rótulo debajo.
struct RoundMenuButton: View {
    let label: String
    let icon: String
    var primary = false
    var busy = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 11) {
                ZStack {
                    Circle().fill(primary ? Color.consoleAccent : hover ? Color(white: 0.2) : Color.consoleSurface)
                    Image(systemName: icon).font(.system(size: 26, weight: .medium))
                        .foregroundStyle(primary ? Color.consoleOnAccent : Color.consoleText)
                        .symbolEffect(.rotate, isActive: busy)
                }
                .frame(width: 74, height: 74)
                .overlay { if hover && !primary { Circle().strokeBorder(Color.consoleAccent, lineWidth: 3) } }
                Text(label).font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color(red: 0xc9 / 255, green: 0xcf / 255, blue: 0xda / 255))
                    .lineLimit(1)
            }
            .frame(width: 96)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(label)
    }
}

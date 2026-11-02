import SwiftUI
import AppKit

/// La colección de Filebox: portadas, ficha, descarga y «Construir».
struct CollectionView: View {
    @Environment(FileboxStore.self) private var store
    @Environment(FileboxDownloads.self) private var downloads
    @Environment(GameLibrary.self) private var library
    @Environment(BuildInbox.self) private var inbox
    @Binding var showBuild: Bool
    @State private var selected: String?
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var showSettings = false
    @State private var error: String?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Todos", missing = "No los tengo", downloaded = "Descargados"
        var id: String { rawValue }
    }

    private func inLibrary(_ g: FBGame) -> Bool {
        guard let t = g.titleId?.uppercased(), !t.isEmpty else { return false }
        return library.games.contains { $0.titleID == t }
    }
    private func isLocal(_ g: FBGame) -> Bool { downloads.zip(g) != nil || downloads.extracted(g) != nil }

    private var shown: [FBGame] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return store.games.filter { g in
            (q.isEmpty || g.title.localizedCaseInsensitiveContains(q) || (g.titleId ?? "").localizedCaseInsensitiveContains(q)
                || (g.publisher ?? "").localizedCaseInsensitiveContains(q))
            && (filter == .all || (filter == .missing ? !inLibrary(g) && !isLocal(g) : isLocal(g)))
        }
    }
    private var current: FBGame? { store.games.first { $0.id == selected } ?? shown.first }

    var body: some View {
        Group {
            if !store.isConfigured {
                ContentUnavailableView {
                    Label("Conecta Filebox", systemImage: "shippingbox")
                } description: {
                    Text("Pon la dirección de la API y un token personal (Mi perfil › Tokens de API) para ver tu colección y descargar los juegos.")
                } actions: {
                    Button("Configurar…") { showSettings = true }.buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        header.padding(.horizontal, 24).padding(.vertical, 16)
                        Divider()
                        if let e = store.error {
                            Label(e, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 24).padding(.vertical, 8)
                                .background(Color.orange.opacity(0.08))
                        }
                        if store.games.isEmpty {
                            ContentUnavailableView(store.loading ? "Cargando la colección…" : "Sin juegos",
                                                   systemImage: "shippingbox",
                                                   description: Text(store.loading ? "" : "Filebox no tiene juegos guardados todavía."))
                        } else {
                            ScrollView {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
                                    ForEach(shown) { g in card(g) }
                                }
                                .padding(24)
                            }
                        }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity)
                    if let g = current {
                        Divider()
                        CollectionDetail(game: g, inLibrary: inLibrary(g), build: { build(g) })
                            .frame(width: 360)
                            .id(g.id)
                    }
                }
            }
        }
        .task {
            // Al abrir: si la caché tiene más de 10 minutos (o no hay), se vuelve a pedir.
            if store.isConfigured, (store.lastSync ?? .distantPast) < Date().addingTimeInterval(-600) { await store.refresh() }
        }
        .sheet(isPresented: $showSettings) {
            FileboxSettingsSheet()
        }
        .alert("No se pudo preparar la build", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Colección").font(.title2.weight(.medium)).foregroundStyle(Color.egluu)
                Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            TextField("Buscar", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
            Button { Task { await store.refresh() } } label: {
                if store.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .help("Volver a pedir la colección").disabled(store.loading)
            .keyboardShortcut("r", modifiers: .command)
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help("Ajustes de Filebox")
        }
    }

    private var subtitle: String {
        let n = store.games.count
        let local = store.games.filter(isLocal).count
        var s = "\(n) juego\(n == 1 ? "" : "s") · \(local) descargado\(local == 1 ? "" : "s")"
        if let d = store.lastSync { s += " · " + d.formatted(.relative(presentation: .named)) }
        return s
    }

    private func card(_ g: FBGame) -> some View {
        let isSel = current?.id == g.id
        return Button { selected = g.id } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Rectangle().fill(Color(nsColor: .controlBackgroundColor))
                    if let c = g.cover {
                        RemoteImage(url: c.thumbUrl, apiBase: store.baseURL).scaledToFill()
                    } else {
                        Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.tertiary)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text(g.title).font(.callout.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(ByteCountFormatter.string(fromByteCount: g.file.size, countStyle: .file))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    CollectionStatusTag(game: g, inLibrary: inLibrary(g))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .contentShape(Rectangle())
            .overlay { Rectangle().strokeBorder(isSel ? Color.egluu : Color(nsColor: .separatorColor), lineWidth: isSel ? 2 : 1) }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if downloads.zip(g) == nil, downloads.extracted(g) == nil, downloads.states[g.id] == nil {
                Button("Descargar") { downloads.start(g, store: store) }
            }
            if isLocal(g) { Button("Construir…") { build(g) } }
        }
    }

    private func build(_ g: FBGame) {
        Task {
            do {
                inbox.pending = try await downloads.gameFiles(g)
                showBuild = true
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Etiqueta de estado de un juego de la colección.
struct CollectionStatusTag: View {
    @Environment(FileboxDownloads.self) private var downloads
    let game: FBGame
    let inLibrary: Bool

    var body: some View {
        switch downloads.states[game.id] {
        case .downloading(let done, let total, _):
            StatusTag(text: "Descargando \(Int(Double(done) / Double(max(total, 1)) * 100)) %", color: .egluuText)
        case .verifying: StatusTag(text: "Comprobando", color: .egluuText)
        case .extracting: StatusTag(text: "Descomprimiendo", color: .egluuText)
        case .failed: StatusTag(text: "Error", color: .red)
        case nil:
            if downloads.isOutdated(game) { StatusTag(text: "Hay versión nueva", color: .orange) }
            else if inLibrary { StatusTag(text: "En la biblioteca", color: .green) }
            else if downloads.zip(game) != nil || downloads.extracted(game) != nil { StatusTag(text: "Descargado", color: .egluuText) }
            else if downloads.partial(game) > 0 { StatusTag(text: "Pausado", color: .orange) }
            else { StatusTag(text: "En Filebox") }
        }
    }
}

/// Panel derecho: portada, ficha, acciones de descarga y capturas.
struct CollectionDetail: View {
    @Environment(FileboxStore.self) private var store
    @Environment(FileboxDownloads.self) private var downloads
    let game: FBGame
    let inLibrary: Bool
    let build: () -> Void

    var body: some View {
        let g = game
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let c = g.cover {
                    RemoteImage(url: c.thumbUrl, apiBase: store.baseURL)
                        .scaledToFit().frame(maxWidth: .infinity, maxHeight: 240)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(g.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text([g.publisher, g.releaseDate.map { String($0.prefix(4)) }, g.version.map { "v\($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                    Text([g.titleId, ByteCountFormatter.string(fromByteCount: g.file.size, countStyle: .file), g.file.name]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                actions(g)
                if let d = g.description, !d.isEmpty {
                    Text(d).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if !g.screenshots.isEmpty {
                    StatusTag(text: "Capturas")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(g.screenshots, id: \.url) { s in
                            Button { if let u = URL(string: s.url) { NSWorkspace.shared.open(u) } } label: {
                                RemoteImage(url: s.thumbUrl, apiBase: store.baseURL).scaledToFill()
                                    .frame(height: 80).clipped()
                            }
                            .buttonStyle(.plain).help("Abrir la captura")
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }

    @ViewBuilder private func actions(_ g: FBGame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch downloads.states[g.id] {
            case .downloading(let done, let total, let bps):
                ProgressView(value: Double(done), total: Double(max(total, 1))).tint(Color.egluu)
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) de \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    Spacer()
                    if bps > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s · " + remaining(Double(total - done) / bps))
                    }
                }
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                HStack {
                    Button("Pausar") { downloads.pause(g) }
                    Button("Cancelar", role: .destructive) { downloads.discardPartial(g) }
                }
            case .verifying(let f):
                ProgressView(value: f) { Text("Comprobando el SHA-256…").font(.callout) }.tint(Color.egluu)
            case .extracting:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Descomprimiendo…").font(.callout) }
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Reintentar") { downloads.clearError(g); downloads.start(g, store: store) }.buttonStyle(.borderedProminent)
                    Button("Descartar") { downloads.discardPartial(g) }
                }
            case nil:
                let local = downloads.zip(g) != nil || downloads.extracted(g) != nil
                if local {
                    Button(action: build) {
                        Label("Construir", systemImage: "hammer.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    if downloads.isOutdated(g) {
                        NoteCallout(text: "En Filebox hay una versión más nueva que la descargada.")
                        Button("Descargar la nueva") { downloads.start(g, store: store) }
                    }
                    HStack {
                        Button("Mostrar en Finder") {
                            if let u = downloads.extracted(g) ?? downloads.zip(g) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                        }
                        Button("Borrar descarga", role: .destructive) { downloads.deleteLocal(g) }
                    }
                    .buttonStyle(.link)
                } else {
                    let part = downloads.partial(g)
                    Button { downloads.start(g, store: store) } label: {
                        Label(part > 0 ? "Continuar descarga" : "Descargar", systemImage: "arrow.down.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    if part > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: part, countStyle: .file)) de \(ByteCountFormatter.string(fromByteCount: g.file.size, countStyle: .file)) ya descargados")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if inLibrary {
                    Label("Ya está en tu biblioteca", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                }
            }
        }
    }

    private func remaining(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "" }
        return Duration.seconds(s).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)) + " restante"
    }
}

/// Imagen remota con caché en memoria. Manda el token solo si la imagen está en el mismo servidor que la API.
struct RemoteImage: View {
    let url: String
    let apiBase: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable() }
            else if failed { Image(systemName: "photo").font(.title).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: url) {
            failed = false
            image = await ImageCache.shared.image(url, apiBase: apiBase)
            failed = image == nil
        }
    }
}

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(_ s: String, apiBase: String) async -> NSImage? {
        if let i = cache.object(forKey: s as NSString) { return i }
        guard let u = URL(string: s) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 30)
        if u.host == URL(string: apiBase)?.host, let t = FileboxStore.readToken() {
            r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 300,
              let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: s as NSString)
        return img
    }
}

/// Ajustes de Filebox: dirección, token (se prueba antes de guardar) y descargas.
struct FileboxSettingsForm: View {
    @Environment(FileboxStore.self) private var store
    @Environment(FileboxDownloads.self) private var downloads
    @State private var base = ""
    @State private var token = ""
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        @Bindable var d = downloads
        Section("Filebox") {
            LabeledContent("Dirección de la API") {
                TextField("http://servidor/api", text: $base).textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            LabeledContent("Token") {
                SecureField(store.hasToken ? "Guardado (escribe otro para cambiarlo)" : "Pega aquí el token", text: $token)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Créalo en Filebox › Mi perfil › Tokens de API. Solo se muestra una vez. Se guarda en este Mac, en un archivo que solo puede leer tu usuario.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(testing ? "Probando…" : "Probar y guardar") { save() }
                    .disabled(testing || base.isEmpty || (token.isEmpty && !store.hasToken))
                    .keyboardShortcut(.defaultAction)
                if store.hasToken {
                    Button("Olvidar el token", role: .destructive) { try? store.setToken(nil); result = nil }
                }
                Spacer()
                if let r = result {
                    Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.ok ? .green : .orange).font(.callout)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Section("Descargas") {
            PathField(title: "Carpeta de descargas", path: $d.folder, mode: .folder, ok: nil)
            Toggle("Borrar el .zip al descomprimirlo para construir", isOn: $d.deleteZipAfterExtract)
        }
        .onAppear { base = store.baseURL }
    }

    private func save() {
        let b = base, t = token.isEmpty ? (FileboxStore.readToken() ?? "") : token
        testing = true; result = nil
        Task {
            defer { testing = false }
            do {
                let n = try await FileboxStore.test(base: b, token: t)
                store.baseURL = b
                if !token.isEmpty { try store.setToken(token); token = "" }
                result = (true, "Conectado: \(n) juego\(n == 1 ? "" : "s")")
                await store.refresh()
            } catch {
                result = (false, error.localizedDescription)
            }
        }
    }
}

struct FileboxSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            Form { FileboxSettingsForm() }.formStyle(.grouped)
            HStack { Spacer(); Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
        }
        .frame(width: 600)
    }
}

import SwiftUI
import AppKit

/// Partidas en la nube de un juego: elige la carpeta (iCloud Drive u otra sincronizada) que el juego usa para compartir su
/// partida con otro Mac o el iPhone. No mueve la carpeta de partidas: el juego copia un único archivo empaquetado, con
/// copias de seguridad y gana la más nueva si se jugó en los dos sin sincronizar.
struct CloudSavesView: View {
    let game: LibraryGame
    @Environment(\.dismiss) private var dismiss
    @Environment(GameLibrary.self) private var library

    @State private var folder: String?
    @State private var appliedToAll = 0

    private var cloud: CloudSaves { CloudSaves(bundleID: game.bundleID, titleID: game.titleID) }
    private var home: String { NSHomeDirectory() }
    private func tilde(_ p: String) -> String { p.replacingOccurrences(of: home, with: "~") }
    private var backups: URL { URL(fileURLWithPath: game.saveURL.path + "-backups") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.title3.bold())
                Text("Partidas en la nube · la misma partida en este Mac, otro Mac o el iPhone")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            Form {
                Section("Carpeta") {
                    if let f = folder {
                        LabeledContent("Sincroniza por") {
                            Text(tilde(f)).textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                        if let svc = CloudFolder.service(of: f, home: home) {
                            Label("En \(svc): se comparte con tus otros dispositivos", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Esta carpeta no está en la nube: la partida solo se copia aquí, no llega a otro equipo",
                                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        fileRow(CloudSaves.file(folder: f, titleID: game.titleID))
                    } else {
                        Text("Desactivadas: la partida solo está en este Mac.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(folder == nil ? "Elegir carpeta…" : "Cambiar carpeta…") { pick() }
                        if folder != nil {
                            Button("Desactivar") { cloud.set(nil); folder = nil }
                            Button("Mostrar en Finder") { reveal() }
                        }
                    }
                }
                if let f = folder, library.games.count > 1 {
                    Section {
                        Button("Usar esta carpeta en todos los juegos (\(library.games.count))") { applyToAll(f) }
                        if appliedToAll > 0 {
                            Text("Hecho: \(appliedToAll) juegos. Cada uno guarda su propio archivo en una subcarpeta con su title ID.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Cómo funciona") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• Tu carpeta de partidas no se mueve. Al arrancar, el juego trae la partida de la nube si es más nueva; unos segundos después de guardar, y al salir, manda la suya.")
                        Text("• En el otro Mac elige la misma carpeta (con NX Build o en la ventana de ajustes del juego). En el iPhone, en «Cloud saves» del lanzador.")
                        Text("• Sal del juego en un equipo y espera unos segundos antes de abrirlo en el otro. Si jugaste en los dos sin sincronizar, gana la partida más nueva.")
                        Text("• Antes de sustituir una partida, el juego guarda una copia: se quedan las 10 últimas de cada lado.")
                        Text("• El cambio vale desde el próximo arranque del juego.")
                    }
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if FileManager.default.fileExists(atPath: backups.path) {
                        Button("Abrir copias de seguridad") { NSWorkspace.shared.open(backups) }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if library.isRunning(game) {
                    Label("El juego está abierto: el cambio vale al volver a abrirlo", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
        .onAppear { folder = cloud.folder }
    }

    @ViewBuilder private func fileRow(_ path: String) -> some View {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        LabeledContent("Archivo") {
            if let d = attrs?[.modificationDate] as? Date {
                Text("save.dmsync · \(d.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("aún no hay (se crea la primera vez que guardes)").foregroundStyle(.secondary)
            }
        }
    }

    private func pick() {
        let start = folder ?? home + "/Library/Mobile Documents/com~apple~CloudDocs"
        guard let u = choose(mode: .folder, start: start, prompt: "Carpeta de partidas en la nube") else { return }
        let p = u.standardizedFileURL.path
        cloud.set(p); folder = p; appliedToAll = 0
    }

    private func reveal() {
        guard let f = folder else { return }
        let file = CloudSaves.file(folder: f, titleID: game.titleID)
        if FileManager.default.fileExists(atPath: file) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: f))
        }
    }

    private func applyToAll(_ f: String) {
        let shared = CloudSaves.shared(folder: f, titleID: game.titleID)
        for g in library.games { CloudSaves(bundleID: g.bundleID, titleID: g.titleID).set(shared) }
        folder = shared; appliedToAll = library.games.count
    }
}

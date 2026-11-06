import SwiftUI
import AppKit

/// Elegir a dónde mover un juego y ver qué se mueve, cuánto ocupa y si cabe. El trabajo lo hace LibraryView con GameMove.
struct MoveGameView: View {
    let game: LibraryGame
    /// Se pulsa Mover: el plan y la carpeta de destino.
    let onMove: (GameMove.Plan, URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var includeExtract = false
    @State private var plan: GameMove.Plan?
    @State private var dest: URL?
    @State private var free: Int64?
    @State private var format: (name: String, ok: Bool)?
    @State private var sameDisk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: game.path)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mover «\(game.name)»").font(.headline)
                    Text(game.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            if let plan {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.items) { it in
                        HStack(spacing: 8) {
                            Text(it.label).font(.caption.bold()).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                            Text(it.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(GameMove.fmt(it.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    HStack {
                        Text(plan.wholeFolder ? "Se mueve la carpeta entera" : "Solo lo de este juego (la carpeta tiene otros)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(GameMove.fmt(plan.bytes)).font(.callout.monospacedDigit().bold())
                    }
                }
                if !plan.dropped.isEmpty || includeExtract {
                    Toggle(isOn: $includeExtract) {
                        Text("Mover también los archivos extraídos (\(GameMove.fmt(includeExtract ? 0 : plan.droppedBytes)) más)")
                    }
                    .help("extract/ y tmp/ de la carpeta de build: la app ya lleva su copia y la siguiente build los vuelve a sacar")
                    if !includeExtract {
                        Text("Sin ellos se borran: la próxima build del juego los vuelve a extraer (unos minutos).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Mirando qué hay que mover…").foregroundStyle(.secondary) }
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Destino").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(dest.map { $0.appendingPathComponent(plan?.folderName ?? "").path } ?? "Sin elegir")
                        .font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(dest == nil ? .secondary : .primary)
                }
                Spacer()
                Button("Elegir…") { pickDest() }
            }
            warnings

            HStack {
                Text("Las partidas no se mueven: van por el title ID.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Mover") {
                    guard let plan, let dest else { return }
                    dismiss()
                    onMove(plan, dest)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canMove)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task(id: includeExtract) {
            let app = game.url, tid = game.titleID, inc = includeExtract
            plan = await Task.detached { GameMove.plan(app: app, titleID: tid, includeExtract: inc) }.value
        }
    }

    private var needsBytes: Int64 { sameDisk ? 0 : (plan?.bytes ?? 0) }
    private var fits: Bool { free.map { $0 >= needsBytes + (1 << 30) } ?? true }
    private var sameFolder: Bool {
        guard let plan, let dest else { return false }
        return dest.appendingPathComponent(plan.folderName).standardizedFileURL == plan.sourceFolder.standardizedFileURL
    }
    private var canMove: Bool { plan != nil && !(plan?.items.isEmpty ?? true) && dest != nil && fits && !sameFolder }

    @ViewBuilder private var warnings: some View {
        if dest != nil {
            VStack(alignment: .leading, spacing: 6) {
                if sameFolder {
                    Label("El juego ya está ahí.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if sameDisk {
                    Label("Mismo disco: se mueve al momento, sin copiar.", systemImage: "bolt.fill").foregroundStyle(.secondary)
                } else if let free {
                    Label("Libres en ese disco: \(GameMove.fmt(free))" + (fits ? "" : " · no cabe"),
                          systemImage: fits ? "internaldrive" : "xmark.octagon.fill")
                        .foregroundStyle(fits ? Color.secondary : Color.red)
                }
                if let f = format, !f.ok {
                    Label("Ese disco es \(f.name): macOS deja archivos «._» junto a cada archivo, la primera build va mucho más lenta y la app de Mac puede no abrir. Mejor un disco APFS (Utilidad de Discos).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
        }
    }

    private func pickDest() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Carpeta donde dejar el juego (se crea dentro una carpeta con su nombre)"
        panel.prompt = "Elegir"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let u = panel.url else { return }
        dest = u
        free = FreeSpace.freeBytes(on: u)
        format = GameMove.volumeFormat(u)
        sameDisk = GameMove.sameVolume(game.url, u)
    }
}

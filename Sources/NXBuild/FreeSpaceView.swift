import SwiftUI

struct FreeSpaceView: View {
    let nspDir: URL
    let extraBuildDirs: [URL]
    @Environment(\.dismiss) private var dismiss

    @State private var dirs: [(dir: URL, groups: [FreeSpace.Group])] = []
    @State private var selected: Set<String> = []        // "<carpeta>|<grupo>"
    @State private var loading = true
    @State private var deleting = false
    @State private var confirm = false
    @State private var result: String?

    private var selectedBytes: Int64 {
        dirs.flatMap { d in d.groups.filter { selected.contains(key(d.dir, $0)) } }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Liberar espacio").font(.title3.bold())
            Text("Borra lo que la siguiente build vuelve a generar. Se conservan logs/, profile/, run/ y nsp/.")
                .font(.callout).foregroundStyle(.secondary)

            if loading {
                HStack { ProgressView().controlSize(.small); Text("Midiendo…") }
            } else if dirs.isEmpty {
                Text("Este juego no tiene carpeta de build.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(dirs, id: \.dir) { d in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(d.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                if d.groups.isEmpty {
                                    Text("Nada que borrar.").font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(d.groups) { g in
                                    Toggle(isOn: binding(key(d.dir, g))) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            HStack {
                                                Text(g.title)
                                                Spacer()
                                                Text(bytes(g.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                            }
                                            Text(g.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)

                Label("La app de Mac guarda el RomFS como clones de extract/: ese espacio no se libera mientras exista la app. Con «RomFS aparte» (iPhone), borra extract/ solo después de pasar la imagen con push_romfs.sh.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result {
                Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(deleting ? "Borrando…" : "Borrar \(bytes(selectedBytes))", role: .destructive) { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || deleting || loading)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load() }
        .confirmationDialog("¿Borrar \(bytes(selectedBytes))?", isPresented: $confirm) {
            Button("Borrar", role: .destructive) { Task { await delete() } }
        } message: {
            Text("No va a la Papelera. La siguiente build lo vuelve a generar, y tardará más.")
        }
    }

    private func key(_ dir: URL, _ g: FreeSpace.Group) -> String { dir.path + "|" + g.id }

    private func binding(_ k: String) -> Binding<Bool> {
        Binding(get: { selected.contains(k) }, set: { if $0 { selected.insert(k) } else { selected.remove(k) } })
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private func load() async {
        loading = true
        let nsp = nspDir, extra = extraBuildDirs
        let found = await Task.detached {
            FreeSpace.buildDirs(for: nsp, extra: extra).map { ($0, FreeSpace.groups(in: $0)) }
        }.value
        dirs = found.map { (dir: $0.0, groups: $0.1) }
        selected = Set(dirs.flatMap { d in d.groups.map { key(d.dir, $0) } })
        loading = false
    }

    private func delete() async {
        deleting = true
        let jobs = dirs.map { d in (d.dir, d.groups.filter { selected.contains(key(d.dir, $0)) }) }.filter { !$0.1.isEmpty }
        let outcome: Result<Int64, Error> = await Task.detached {
            do {
                var freed: Int64 = 0
                for (dir, groups) in jobs { freed += try FreeSpace.delete(groups, in: dir) ?? 0 }
                return .success(freed)
            } catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let freed): result = "Disco con \(bytes(max(freed, 0))) más libres."
        case .failure(let e): result = "Error: \(e.localizedDescription)"
        }
        deleting = false
        await load()
    }
}

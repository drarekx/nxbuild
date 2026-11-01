import SwiftUI

struct DependenciesView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Dependencies.self) private var deps

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            List(DepID.allCases) { id in row(id) }
                .frame(minHeight: 300)
            Divider()
            LogView(lines: deps.installLog)
                .frame(minHeight: 160)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 640, minHeight: 600)
        .task { if deps.status.isEmpty { await deps.check(settings: settings) } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dependencias").font(.title3.bold())
                Group {
                    if let cur = deps.currentInstall { Text("Instalando \(cur)…") }
                    else if deps.checking { Text("Comprobando…") }
                    else if deps.missingAny { Text("Faltan cosas para construir") }
                    else { Text("Todo listo") }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { NSWorkspace.shared.open(Dependencies.reportURL) } label: { Label("Informe", systemImage: "doc.text") }
                .help("deps-check.txt: veredictos, intérpretes probados, HOME y PATH")
                .disabled(!FileManager.default.fileExists(atPath: Dependencies.reportURL.path))
            Button {
                Task { await deps.check(settings: settings) }
            } label: { Label("Comprobar", systemImage: "arrow.clockwise") }
            .disabled(deps.checking || deps.installing)
            Button {
                Task { await deps.installAll(settings: settings) }
            } label: { Label("Instalar todo lo que falta", systemImage: "arrow.down.circle.fill") }
            .buttonStyle(.borderedProminent)
            .disabled(deps.checking || deps.installing || !deps.missingAny)
        }
    }

    private func row(_ id: DepID) -> some View {
        let st = deps.state(id)
        return HStack(spacing: 10) {
            Group {
                switch st.state {
                case .unknown: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                case .checking: ProgressView().controlSize(.small)
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .warning: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(id.title)
                    if id.iosOnly { Text("solo IPA").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: .capsule) }
                }
                if !st.detail.isEmpty {
                    Text(st.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if let a = st.action, st.state != .ok, st.state != .checking {
                Button {
                    Task { await deps.perform(a, for: id, settings: settings) }
                } label: {
                    switch a {
                    case .terminal: Label(a.label, systemImage: "terminal")
                    case .link: Label(a.label, systemImage: "safari")
                    case .inApp: Text(a.label)
                    }
                }
                .disabled(deps.installing)
            }
        }
        .padding(.vertical, 3)
    }
}

import SwiftUI
import AppKit

@main
struct NXBuildApp: App {
    @State private var settings = AppSettings()
    @State private var runner = BuildRunner()
    @State private var deps = Dependencies()
    @State private var library = GameLibrary()
    @State private var filebox = FileboxStore()
    @State private var downloads = FileboxDownloads()
    @State private var inbox = BuildInbox()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("NX Build", id: "main") {
            RootView()
                .environment(settings)
                .environment(runner)
                .environment(deps)
                .environment(library)
                .environment(filebox)
                .environment(downloads)
                .environment(inbox)
                .frame(minWidth: 1060, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckUpdatesButton()
            }
            CommandGroup(after: .appSettings) {
                OpenDepsButton()
            }
        }

        Window("Dependencias", id: "deps") {
            DependenciesView()
                .environment(settings)
                .environment(deps)
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(filebox)
                .environment(downloads)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ejecutable de SwiftPM sin bundle: que se comporte como app normal (Dock, foco).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        MainActor.assumeIsolated { Updater.shared.start() }
    }
    /// Cerrar la ventana no sale mientras hay una build: sigue en segundo plano y el Dock vuelve a abrirla.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !(BuildRunner.active?.isRunning ?? false) }
    }

    /// Salir con una build en marcha la para entera (todo su grupo de procesos), tras confirmarlo.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let runner = BuildRunner.active, runner.isRunning else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Hay una build en marcha"
            alert.informativeText = "Si sales, se para la build y todos los procesos que ha lanzado."
            alert.addButton(withTitle: "Parar y salir")
            alert.addButton(withTitle: "Seguir")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            BuildRunner.stopGroupForQuit(runner.pgid)
            return .terminateNow
        }
    }
}

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        Form {
            PathField(title: "Python del venv", path: $s.pythonPath, mode: .file, ok: settings.pythonOK)
            PathField(title: "Repositorio nxnative", path: $s.repoPath, mode: .folder, ok: settings.scriptOK)
            PathField(title: "prod.keys por defecto", path: $s.keysPath, mode: .file,
                      ok: FileManager.default.fileExists(atPath: settings.keysPath))
            PathField(title: "Carpeta inicial al elegir juego", path: $s.defaultBrowseDir, mode: .folder, ok: nil)
            Toggle("Avisar al terminar una build (si la app no está delante)", isOn: $s.notifyOnFinish)
            Toggle("Jugar sin la ventana de ajustes del juego (las opciones se eligen aquí)", isOn: $s.skipGameWindow)
            FileboxSettingsForm()
            Section("Portadas") {
                Toggle("Usar la portada de Filebox cuando el juego esté en la colección",
                       isOn: Binding(get: { Covers.shared.preferFilebox }, set: { Covers.shared.preferFilebox = $0 }))
                Text("Si no, o sin conexión la primera vez, se usa el icono del NSP. Cada juego puede elegir la suya con clic derecho en el inicio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Actualizaciones") {
                Toggle("Buscar actualizaciones automáticamente", isOn: Binding(get: { Updater.shared.autoCheck },
                                                                                set: { Updater.shared.autoCheck = $0 }))
                LabeledContent("Versión", value: Updater.currentVersion)
                CheckUpdatesButton()
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .padding()
    }
}

struct PathField: View {
    enum Mode { case file, folder }
    let title: String
    @Binding var path: String
    let mode: Mode
    let ok: Bool?

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField("", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let ok {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? .green : .orange)
                }
                Button("Elegir…") {
                    if let url = choose(mode: mode, start: path) { path = url.path }
                }
            }
        }
    }
}

@MainActor
func choose(mode: PathField.Mode, start: String, prompt: String? = nil) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = mode == .file
    panel.canChooseDirectories = mode == .folder
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    if let prompt { panel.message = prompt }
    var dir = URL(fileURLWithPath: start)
    if mode == .file || !FileManager.default.fileExists(atPath: dir.path) { dir.deleteLastPathComponent() }
    if FileManager.default.fileExists(atPath: dir.path) { panel.directoryURL = dir }
    return panel.runModal() == .OK ? panel.url : nil
}

struct OpenDepsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Dependencias…") { openWindow(id: "deps") }
            .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}

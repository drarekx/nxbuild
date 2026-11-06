import AppKit
import UserNotifications

/// Aviso del sistema cuando una build termina o falla con la app en segundo plano: una build tarda lo bastante como
/// para cambiar de ventana, y la única señal era la ventana que se dejó atrás. Pulsarlo trae la app al frente.
/// Necesita el paquete .app (identificador de bundle): con `swift run` no hace nada.
@MainActor
final class BuildNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BuildNotifier()

    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    /// Pide permiso la primera vez (al empezar la primera build, no al abrir la app).
    func prepare() {
        guard available else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        // Versión async: el cierre de la versión con completion hereda el MainActor de la clase y el sistema
        // lo llama en una cola de fondo, lo que tumba la app (dispatch_assert_queue) en la primera build.
        Task { _ = try? await c.requestAuthorization(options: [.alert, .sound]) }
    }

    func notify(title: String, body: String, success: Bool) {
        guard available, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: "build-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "NX Build" }?.makeKeyAndOrderFront(nil)
        }
    }

    /// Con la app delante no se muestra (ya se ve la ventana).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}

/// El icono del Dock con una barra de progreso abajo, como una descarga de la App Store, para ver la build desde donde sea.
@MainActor
enum DockProgress {
    private static var bar: NSProgressIndicator?
    private static var shown: Double = -1

    /// fraction 0…1; nil quita la barra.
    static func set(_ fraction: Double?) {
        let tile = NSApp.dockTile
        guard let f = fraction else {
            if bar != nil { tile.contentView = nil; bar = nil; shown = -1; tile.display() }
            return
        }
        let v = min(max(f, 0), 1)
        if bar == nil {
            let size = tile.size
            let view = NSView(frame: NSRect(origin: .zero, size: size))
            let icon = NSImageView(frame: view.bounds)
            icon.image = NSApp.applicationIconImage
            icon.imageScaling = .scaleProportionallyUpOrDown
            view.addSubview(icon)
            let p = NSProgressIndicator(frame: NSRect(x: size.width * 0.1, y: size.height * 0.08,
                                                      width: size.width * 0.8, height: max(12, size.height * 0.12)))
            p.style = .bar
            p.isIndeterminate = false
            p.minValue = 0; p.maxValue = 1
            view.addSubview(p)
            tile.contentView = view
            bar = p
        }
        guard abs(v - shown) >= 0.005 else { return }   // redibujar el Dock solo cuando se nota
        shown = v
        bar?.doubleValue = v
        tile.display()
    }

    /// Progreso total: etapas acabadas más la fracción de la actual.
    static func overall(stage k: Int, of n: Int, frac: Double?) -> Double? {
        guard n > 0, k > 0 else { return nil }
        return (Double(k - 1) + (frac ?? 0)) / Double(n)
    }
}

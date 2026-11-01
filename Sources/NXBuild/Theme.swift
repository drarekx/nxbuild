import SwiftUI
import AppKit

/// Colores y tipos de egluu (Egluu design system): cian de marca para líneas, fondos y titulares grandes; su versión
/// oscurecida para texto pequeño (el cian de marca no llega a 3:1 sobre blanco); Roboto Mono → monoespaciada del sistema.
extension Color {
    static let egluu = Color(red: 0x42 / 255, green: 0xb5 / 255, blue: 0xc7 / 255)
    /// accent-text: #297d8a en claro, #7fd0dc en oscuro.
    static let egluuText = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x7f / 255, green: 0xd0 / 255, blue: 0xdc / 255, alpha: 1)
            : NSColor(srgbRed: 0x29 / 255, green: 0x7d / 255, blue: 0x8a / 255, alpha: 1)
    })
    /// accent-soft: #f2fafb en claro, #102e33 en oscuro.
    static let egluuSoft = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x10 / 255, green: 0x2e / 255, blue: 0x33 / 255, alpha: 1)
            : NSColor(srgbRed: 0xf2 / 255, green: 0xfa / 255, blue: 0xfb / 255, alpha: 1)
    })
}

/// Etiqueta de estado en mayúsculas y monoespaciada, siempre con palabra (nunca solo color).
struct StatusTag: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(color)
    }
}

/// Encabezado de paso: «01  Juego», número en cian oscuro y título monoespaciado.
struct StepHeader: View {
    let number: Int
    let title: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(format: "%02d", number))
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.egluuText)
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
        }
    }
}

/// Aviso con línea cian a la izquierda (Callout de egluu), recto.
struct NoteCallout: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.egluuSoft)
            .overlay(alignment: .leading) { Rectangle().fill(Color.egluu).frame(width: 3) }
    }
}

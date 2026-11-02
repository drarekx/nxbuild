import Foundation
import AppKit
import Observation
import CryptoKit

/// De dónde sale la portada de un juego de la biblioteca: el icono del NSP (AppIcon.icns que nxnative mete en la app,
/// 256 px) o la portada de Filebox del juego con el mismo title ID (más grande). Preferencia general más una elección
/// por juego; las de Filebox se guardan en disco para verlas sin conexión.
@MainActor @Observable
final class Covers {
    enum Source: String, CaseIterable, Identifiable {
        case auto, game, filebox
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: "Automática"
            case .game: "Icono del juego (NSP)"
            case .filebox: "Portada de Filebox"
            }
        }
    }

    static let shared = Covers()

    /// Usar la portada de Filebox cuando el juego está allí (si no, el icono del juego).
    var preferFilebox: Bool { didSet { UserDefaults.standard.set(preferFilebox, forKey: "covers.preferFilebox") } }
    /// title ID → .game o .filebox (sin entrada: automática).
    private(set) var overrides: [String: Source]

    private let memory = NSCache<NSString, NSImage>()
    nonisolated static var dir: URL { FileboxStore.dir.appendingPathComponent("covers") }

    private init() {
        let d = UserDefaults.standard
        preferFilebox = d.object(forKey: "covers.preferFilebox") as? Bool ?? true
        overrides = (d.dictionary(forKey: "covers.override") as? [String: String] ?? [:]).compactMapValues(Source.init(rawValue:))
    }

    func choice(for g: LibraryGame) -> Source { overrides[g.titleID] ?? .auto }

    func set(_ s: Source, for g: LibraryGame) {
        overrides[g.titleID] = s == .auto ? nil : s
        UserDefaults.standard.set(overrides.mapValues(\.rawValue), forKey: "covers.override")
    }

    /// ¿Toca la de Filebox para este juego?
    func wantsFilebox(_ g: LibraryGame) -> Bool {
        switch choice(for: g) {
        case .game: false
        case .filebox: true
        case .auto: preferFilebox
        }
    }

    /// La portada de Filebox del juego con el mismo title ID, si la hay en la colección (también la de la caché).
    func fileboxCover(for g: LibraryGame, in store: FileboxStore) -> FBImage? {
        guard !g.titleID.isEmpty else { return nil }
        return store.games.first { $0.titleId?.uppercased() == g.titleID && $0.cover != nil }?.cover
    }

    /// Icono del NSP que lleva la app.
    func gameIcon(_ g: LibraryGame) -> NSImage? {
        let key = "icon:" + g.path as NSString
        if let i = memory.object(forKey: key) { return i }
        guard let i = NSImage(contentsOf: g.url.appendingPathComponent("Contents/Resources/AppIcon.icns")) else { return nil }
        memory.setObject(i, forKey: key)
        return i
    }

    /// Imagen de Filebox: memoria, luego disco (covers/<sha de la URL sin la firma>), luego red.
    func remote(_ img: FBImage, apiBase: String) async -> NSImage? {
        let stable = img.url.split(separator: "?").first.map(String.init) ?? img.url   // las URL firmadas cambian la query
        let name = SHA256.hash(data: Data(stable.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let key = "fb:" + name as NSString
        if let i = memory.object(forKey: key) { return i }
        let file = Self.dir.appendingPathComponent(name)
        if let i = NSImage(contentsOf: file) { memory.setObject(i, forKey: key); return i }
        guard let i = await ImageCache.shared.image(img.url, apiBase: apiBase) else { return nil }
        if let tiff = i.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
        }
        memory.setObject(i, forKey: key)
        return i
    }
}

import Foundation

/// Los ajustes que ofrece una app de Mac construida: Contents/Resources/dm/launcher.json (dm/games/settings.py desde
/// settings.tsv; docs/frontends.md). Tipos: choice (opciones [valor, nombre]), toggle (valores on / off) y range
/// (min, max, step). `needs` = "<VAR>=<valor>": fila que solo se dibuja mientras otra tiene ese valor.
struct LaunchSetting: Decodable, Identifiable, Equatable, Sendable {
    let env: String
    let kind: String
    let section: String?
    let label: String
    let note: String?
    let level: String?
    let needs: String?
    let options: [[String]]?
    let on: String?
    let off: String?
    let min: Double?
    let max: Double?
    let step: Double?
    private let defaultRaw: String

    var id: String { env }
    var defaultValue: String { defaultRaw }
    var isBasic: Bool { level == "basic" }

    enum CodingKeys: String, CodingKey {
        case env, kind, section, label, note, level, needs, options, on, off, min, max, step
        case defaultRaw = "default"
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        env = try c.decode(String.self, forKey: .env)
        kind = try c.decode(String.self, forKey: .kind)
        section = try c.decodeIfPresent(String.self, forKey: .section)
        label = try c.decode(String.self, forKey: .label)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        level = try c.decodeIfPresent(String.self, forKey: .level)
        needs = try c.decodeIfPresent(String.self, forKey: .needs)
        options = try c.decodeIfPresent([[String]].self, forKey: .options)
        on = try c.decodeIfPresent(String.self, forKey: .on)
        off = try c.decodeIfPresent(String.self, forKey: .off)
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
        step = try c.decodeIfPresent(Double.self, forKey: .step)
        // El valor por defecto suele ser texto; por si acaso, también número.
        if let s = try? c.decode(String.self, forKey: .defaultRaw) { defaultRaw = s }
        else if let n = try? c.decode(Double.self, forKey: .defaultRaw) { defaultRaw = String(n) }
        else { defaultRaw = "" }
    }

    /// ¿Acepta el launcher este valor guardado? (launcher.c lo comprueba igual al leerlo).
    func accepts(_ v: String) -> Bool {
        switch kind {
        case "choice": return options?.contains { $0.first == v } ?? false
        case "toggle": return v == on || v == off
        case "range":
            guard let x = Double(v) else { return false }
            return x >= (min ?? -.infinity) - 1e-9 && x <= (max ?? .infinity) + 1e-9
        default: return true
        }
    }

    /// ¿Es el valor por defecto? Los range se comparan como número ("1" == "1.0").
    func isDefault(_ v: String) -> Bool {
        if kind == "range", let a = Double(v), let b = Double(defaultValue) { return abs(a - b) < 1e-9 }
        return v == defaultValue
    }

    /// Texto de un número de range con los decimales del paso.
    func format(_ x: Double) -> String {
        let decimals = step.map { s -> Int in
            var d = 0, v = s
            while d < 6 && abs(v.rounded() - v) > 1e-9 { v *= 10; d += 1 }
            return d
        } ?? 2
        return String(format: "%.\(decimals)f", x)
    }
}

struct LaunchSettingsFile: Decodable, Sendable {
    let schema: Int?
    let game: String?
    let settings: [LaunchSetting]

    static func load(app: URL) -> LaunchSettingsFile? {
        let url = app.appendingPathComponent("Contents/Resources/dm/launcher.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LaunchSettingsFile.self, from: data)
    }
}

/// Las opciones guardadas del jugador: `launcher.<VAR>` (texto) en el dominio de preferencias de la app (su bundle ID).
/// launcher.c las lee en cada arranque, también desde Finder o el Dock. Solo se guarda lo que difiere del valor
/// probado; elegir el valor por defecto borra la clave.
struct SavedChoices {
    let bundleID: String

    private var domain: CFString { bundleID as CFString }

    func value(_ env: String) -> String? {
        CFPreferencesAppSynchronize(domain)
        let v = CFPreferencesCopyAppValue("launcher.\(env)" as CFString, domain)
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }   // un `defaults write` sin -string
        return nil
    }

    /// El valor efectivo: el guardado si la build lo acepta, si no el por defecto.
    func effective(_ s: LaunchSetting) -> String {
        if let v = value(s.env), s.accepts(v) { return v }
        return s.defaultValue
    }

    func set(_ s: LaunchSetting, _ v: String) {
        let key = "launcher.\(s.env)" as CFString
        CFPreferencesSetAppValue(key, s.isDefault(v) ? nil : v as CFString, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// «Restablecer»: borra las claves de los ajustes que ofrece la app.
    func reset(_ settings: [LaunchSetting]) {
        for s in settings { CFPreferencesSetAppValue("launcher.\(s.env)" as CFString, nil, domain) }
        CFPreferencesAppSynchronize(domain)
    }

    /// Cuántos ajustes difieren del valor probado.
    func changedCount(_ settings: [LaunchSetting]) -> Int {
        settings.filter { s in value(s.env).map { s.accepts($0) && !s.isDefault($0) } ?? false }.count
    }

    /// ¿Se dibuja la fila? (`needs`: solo mientras la variable de la que depende tiene ese valor).
    func visible(_ s: LaunchSetting, in all: [LaunchSetting]) -> Bool {
        guard let n = s.needs, let eq = n.firstIndex(of: "=") else { return true }
        let v = String(n[..<eq]), want = String(n[n.index(after: eq)...])
        guard let parent = all.first(where: { $0.env == v }) else { return true }
        return effective(parent) == want
    }
}

/// Partidas en la nube del juego (docs/frontends.md, The cloud saves folder): la clave `cloudSaves.folder` en sus
/// preferencias. launcher.c la lee en cada arranque y la pasa como DM_SAVE_SYNC; el juego guarda ahí un solo archivo,
/// <carpeta>/<title ID>/save.dmsync (o <carpeta>/save.dmsync si la carpeta ya se llama como el title ID), lo trae al
/// arrancar si es el bueno y lo manda tras guardar y al salir. La carpeta de partidas del juego no se mueve nunca.
struct CloudSaves {
    let bundleID: String
    let titleID: String

    private var domain: CFString { bundleID as CFString }
    private static var key: CFString { "cloudSaves.folder" as CFString }

    var folder: String? {
        CFPreferencesAppSynchronize(domain)
        guard let s = CFPreferencesCopyAppValue(Self.key, domain) as? String, !s.isEmpty else { return nil }
        return s
    }

    /// nil = desactivar.
    func set(_ path: String?) {
        CFPreferencesSetAppValue(Self.key, path.map { $0 as CFString }, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// El archivo que usa el juego dentro de la carpeta.
    static func file(folder: String, titleID: String) -> String {
        let f = (folder as NSString).standardizingPath
        if (f as NSString).lastPathComponent.caseInsensitiveCompare(titleID) == .orderedSame {
            return f + "/save.dmsync"
        }
        return f + "/\(titleID)/save.dmsync"
    }

    /// Para usar una carpeta en toda la biblioteca: si es la carpeta propia de un juego (<…>/<title ID>), la de arriba.
    static func shared(folder: String, titleID: String) -> String {
        let f = (folder as NSString).standardizingPath
        return (f as NSString).lastPathComponent.caseInsensitiveCompare(titleID) == .orderedSame
            ? (f as NSString).deletingLastPathComponent : f
    }
}

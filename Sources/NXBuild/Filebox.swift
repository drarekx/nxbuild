import Foundation
import Observation

// Filebox: la web propia donde se suben los juegos en .zip. API (OpenAPI 3.1, «Filebox API» 1.0.0):
//   GET {base}/v1/games?search=&updated_since=&per_page=  (Authorization: Bearer <token>) → GameListData, paginado
//   Cada juego trae file.download.url: URL firmada que caduca (6 h por defecto), sin token, admite Range.

/// Un juego de la colección (GameData).
struct FBGame: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var titleId: String?
    var version: String?
    var description: String?
    var publisher: String?
    var releaseDate: String?
    var file: FBFile
    var cover: FBImage?
    var screenshots: [FBImage]
    var createdAt: String
    var updatedAt: String
}

struct FBFile: Codable, Equatable, Sendable {
    var name: String
    var size: Int64
    var mime: String?
    var sha256: String?
    var download: FBDownload
}

struct FBDownload: Codable, Equatable, Sendable {
    var url: String
    var expiresAt: String
    /// Caduca en menos de un minuto (o ya caducó): hay que volver a pedir el listado.
    var isExpired: Bool { (Filebox.date(expiresAt) ?? .distantPast) < Date().addingTimeInterval(60) }
}

struct FBImage: Codable, Equatable, Sendable {
    var url: String
    var thumbUrl: String
    var mime: String
    var size: Int64
}

struct FBPage: Codable, Sendable {
    var data: [FBGame]
    var meta: Meta
    struct Meta: Codable, Sendable {
        var currentPage: Int
        var lastPage: Int
        var perPage: Int
        var total: Int
        var nextPageUrl: String?
        var prevPageUrl: String?
    }
}

enum Filebox {
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let lock = NSLock()
    static func date(_ s: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
    static func string(_ d: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return iso.string(from: d)
    }

    enum Failure: LocalizedError, Equatable {
        case notConfigured
        case badURL(String)
        case unauthorized
        case http(Int, String)
        case offline(String)
        case decoding(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Falta configurar Filebox: la dirección de la API y el token."
            case .badURL(let u): "La dirección de la API no es válida: \(u)"
            case .unauthorized: "Filebox no acepta el token (401). Crea otro en Mi perfil › Tokens de API y pégalo en Ajustes."
            case .http(let c, let m): "Filebox respondió \(c)\(m.isEmpty ? "" : ": \(m)")"
            case .offline(let m): "No se pudo conectar con Filebox: \(m)"
            case .decoding(let m): "La respuesta de Filebox no tiene el formato esperado: \(m)"
            }
        }
    }
}

/// Cliente de la API. Sin estado: base y token se pasan al crearlo. El token va solo en la cabecera Authorization
/// de las peticiones a la propia API (nunca a la URL de descarga, que va firmada) y nunca se escribe en logs.
struct FileboxClient: Sendable {
    var base: URL
    var token: String
    var session: URLSession = .shared

    init(base: String, token: String, session: URLSession = .shared) throws {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard let u = URL(string: b), let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil else {
            throw Filebox.Failure.badURL(base)
        }
        self.base = u; self.token = token; self.session = session
    }

    /// Todas las páginas de /v1/games (100 por página), siguiendo meta.nextPageUrl.
    func games(updatedSince: Date? = nil, search: String? = nil) async throws -> [FBGame] {
        var c = URLComponents(url: base.appendingPathComponent("v1/games"), resolvingAgainstBaseURL: false)!
        var q = [URLQueryItem(name: "per_page", value: "100")]
        if let updatedSince { q.append(URLQueryItem(name: "updated_since", value: Filebox.string(updatedSince))) }
        if let search, !search.isEmpty { q.append(URLQueryItem(name: "search", value: search)) }
        c.queryItems = q
        var next: URL? = c.url
        var out: [FBGame] = []
        var seen = Set<String>()
        while let url = next {
            let page: FBPage = try await get(url)
            out += page.data
            next = page.meta.nextPageUrl.flatMap(URL.init(string:))
            // Defensa ante un servidor que devuelva siempre la misma página siguiente.
            if let n = next, !seen.insert(n.absoluteString).inserted { break }
            if page.data.isEmpty { break }
        }
        return out
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: r) }
        catch { throw Filebox.Failure.offline(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw Filebox.Failure.unauthorized }
        guard (200..<300).contains(code) else {
            let msg = (try? JSONDecoder().decode([String: AnyCodable].self, from: data))?["message"]?.text ?? ""
            throw Filebox.Failure.http(code, msg)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw Filebox.Failure.decoding(String(describing: error).prefix(300).description) }
    }
}

/// Solo para leer «message» de un error JSON sin conocer el resto.
private struct AnyCodable: Decodable {
    var text: String?
    init(from d: Decoder) throws { text = try? d.singleValueContainer().decode(String.self) }
}

/// Configuración y colección: dirección de la API (UserDefaults), token (archivo 0600 en Application Support: el
/// Llavero pediría permiso tras cada actualización, porque la firma ad hoc cambia) y el último listado (caché JSON).
@MainActor @Observable
final class FileboxStore {
    static let defaultBase = "http://192.168.100.178/api"
    nonisolated static let dir = Dependencies.venvDir.deletingLastPathComponent()
    nonisolated static var tokenURL: URL { dir.appendingPathComponent("filebox-token") }
    nonisolated static var cacheURL: URL { dir.appendingPathComponent("filebox-games.json") }

    var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: "filebox.baseURL") } }
    private(set) var hasToken: Bool
    private(set) var games: [FBGame] = []
    private(set) var lastSync: Date?
    private(set) var loading = false
    var error: String?

    init() {
        baseURL = UserDefaults.standard.string(forKey: "filebox.baseURL") ?? Self.defaultBase
        hasToken = FileManager.default.fileExists(atPath: Self.tokenURL.path)
        if let d = try? Data(contentsOf: Self.cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d) {
            games = c.games; lastSync = c.synced
        }
    }

    private struct Cache: Codable { var synced: Date; var games: [FBGame] }

    var isConfigured: Bool { hasToken && !baseURL.isEmpty }

    nonisolated static func readToken() -> String? {
        (try? String(contentsOf: tokenURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Guarda (o borra, con nil/vacío) el token. Archivo nuevo con permisos 0600 antes de escribir.
    func setToken(_ token: String?) throws {
        let fm = FileManager.default
        let t = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty {
            try? fm.removeItem(at: Self.tokenURL)
        } else {
            try fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: Self.tokenURL)
            guard fm.createFile(atPath: Self.tokenURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let h = try FileHandle(forWritingTo: Self.tokenURL)
            try h.write(contentsOf: Data(t.utf8)); try h.close()
        }
        hasToken = fm.fileExists(atPath: Self.tokenURL.path)
    }

    func client() throws -> FileboxClient {
        guard let t = Self.readToken() else { throw Filebox.Failure.notConfigured }
        return try FileboxClient(base: baseURL, token: t)
    }

    /// Prueba la conexión con una base y un token concretos (antes de guardarlos). Devuelve cuántos juegos hay.
    nonisolated static func test(base: String, token: String) async throws -> Int {
        let c = try FileboxClient(base: base, token: token)
        var comp = URLComponents(url: c.base.appendingPathComponent("v1/games"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "per_page", value: "1")]
        var r = URLRequest(url: comp.url!, timeoutInterval: 15)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: r) }
        catch { throw Filebox.Failure.offline(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw Filebox.Failure.unauthorized }
        guard (200..<300).contains(code) else { throw Filebox.Failure.http(code, "") }
        guard let page = try? JSONDecoder().decode(FBPage.self, from: data) else {
            throw Filebox.Failure.decoding("¿es la dirección de la API (…/api)?")
        }
        return page.meta.total
    }

    /// Pide la colección entera (así también desaparecen los juegos borrados en la web) y la guarda en caché.
    func refresh() async {
        guard isConfigured, !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let list = try await client().games()
            games = list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            lastSync = Date()
            if let d = try? JSONEncoder().encode(Cache(synced: lastSync!, games: games)) {
                try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                try? d.write(to: Self.cacheURL, options: .atomic)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// El juego con su enlace de descarga vigente: si el de la caché caducó, vuelve a pedir el listado.
    func fresh(_ g: FBGame, force: Bool = false) async throws -> FBGame {
        if !force, !g.file.download.isExpired { return g }
        let c = try client()
        var found = try await c.games(search: g.title).first { $0.id == g.id }
        if found == nil { found = try await c.games().first { $0.id == g.id } }
        guard let found else { throw Filebox.Failure.http(404, "el juego ya no está en Filebox") }
        if let i = games.firstIndex(where: { $0.id == g.id }) { games[i] = found }
        return found
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

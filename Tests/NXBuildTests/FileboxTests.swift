import Foundation
import Testing
import CryptoKit
@testable import NXBuild

/// Servidor falso para URLSession: responde según la ruta, con Range para /dl/.
final class FakeFilebox: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var honorRange = true
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "filebox.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let url = request.url!
        func send(_ code: Int, _ body: Data, _ headers: [String: String] = [:]) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if url.path.hasPrefix("/api/v1/games") {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer secreto" else {
                return send(401, Data(#"{"message":"Unauthenticated."}"#.utf8))
            }
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value ?? "1"
            return send(200, Data(Self.page(Int(page)!).utf8), ["Content-Type": "application/json"])
        }
        if url.path.hasPrefix("/dl/") {
            if url.path == "/dl/expired" { return send(403, Data("expired".utf8)) }
            if Self.honorRange, let r = request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") {
                let start = Int(r.dropFirst(6).dropLast())!
                let body = Self.payload.subdata(in: start..<Self.payload.count)
                return send(206, body, ["Content-Range": "bytes \(start)-\(Self.payload.count - 1)/\(Self.payload.count)"])
            }
            return send(200, Self.payload)
        }
        send(404, Data())
    }

    static func game(_ n: Int) -> String {
        """
        {"id":"id-\(n)","title":"Juego \(n)","titleId":"0100000000010000","version":"1.0","description":null,"publisher":"Pub",
         "releaseDate":"2020-01-01","file":{"name":"juego\(n).zip","size":10,"mime":"application/zip","sha256":null,
         "download":{"url":"http://filebox.test/dl/\(n)","expiresAt":"2099-01-01T00:00:00.000000Z"}},
         "cover":{"url":"http://filebox.test/c.png","thumbUrl":"http://filebox.test/c.webp","mime":"image/png","size":1},
         "screenshots":[],"createdAt":"2026-11-01T10:00:00.000000Z","updatedAt":"2026-11-01T10:00:00.000000Z"}
        """
    }
    static func page(_ p: Int) -> String {
        let next = p < 2 ? "\"http://filebox.test/api/v1/games?per_page=100&page=\(p + 1)\"" : "null"
        let items = p == 1 ? [game(1), game(2)] : [game(3)]
        return """
        {"data":[\(items.joined(separator: ","))],"meta":{"currentPage":\(p),"lastPage":2,"perPage":2,"total":3,
         "nextPageUrl":\(next),"prevPageUrl":null}}
        """
    }
}

@Suite(.serialized) struct FileboxTests {
    let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeFilebox.self]
        return URLSession(configuration: c)
    }()

    @Test func followsPagesAndSendsToken() async throws {
        FakeFilebox.requests = []
        let c = try FileboxClient(base: "http://filebox.test/api/", token: "secreto", session: session)
        let games = try await c.games()
        #expect(games.map(\.id) == ["id-1", "id-2", "id-3"])
        #expect(games[0].cover?.thumbUrl == "http://filebox.test/c.webp")
        #expect(FakeFilebox.requests.first?.url?.query?.contains("per_page=100") == true)
        #expect(FakeFilebox.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secreto" })
    }

    @Test func badTokenIsUnauthorized() async throws {
        let c = try FileboxClient(base: "http://filebox.test/api", token: "otro", session: session)
        await #expect(throws: Filebox.Failure.unauthorized) { try await c.games() }
    }

    @Test func rejectsBadBase() {
        #expect(throws: Filebox.Failure.self) { try FileboxClient(base: "192.168.1.1/api", token: "x") }
    }

    @Test func parsesDatesWithMicroseconds() {
        #expect(Filebox.date("2026-11-01T10:00:00.000000Z") != nil)
        #expect(Filebox.date("2026-11-01T10:00:00Z") != nil)
        #expect(FBDownload(url: "", expiresAt: "2000-01-01T00:00:00Z").isExpired)
        #expect(!FBDownload(url: "", expiresAt: "2099-01-01T00:00:00Z").isExpired)
    }

    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func withFakeProtocol<T>(_ body: () async throws -> T) async rethrows -> T { try await body() }
    private var fakeConfig: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [FakeFilebox.self]; return c
    }

    @Test func resumesFromPartialFile() async throws {
        FakeFilebox.payload = Data((0..<200_000).map { UInt8($0 % 251) })
        FakeFilebox.honorRange = true
        FakeFilebox.requests = []
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let part = d.appendingPathComponent("j.zip.part")
        try FakeFilebox.payload.prefix(70_000).write(to: part)
        try await withFakeProtocol {
            try await RangeDownload(url: URL(string: "http://filebox.test/dl/1")!, part: part,
                                    expected: Int64(FakeFilebox.payload.count), configuration: fakeConfig) { _ in }.run()
        }
        #expect(try Data(contentsOf: part) == FakeFilebox.payload)
        #expect(FakeFilebox.requests.last?.value(forHTTPHeaderField: "Range") == "bytes=70000-")
        let want = SHA256.hash(data: FakeFilebox.payload).map { String(format: "%02x", $0) }.joined()
        #expect(try sha256(of: part) { _ in } == want)
    }

    @Test func restartsWhenServerIgnoresRange() async throws {
        FakeFilebox.payload = Data((0..<50_000).map { UInt8($0 % 7) })
        FakeFilebox.honorRange = false
        defer { FakeFilebox.honorRange = true }
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let part = d.appendingPathComponent("j.part")
        try Data(repeating: 9, count: 20_000).write(to: part)   // basura que no es el principio
        try await withFakeProtocol {
            try await RangeDownload(url: URL(string: "http://filebox.test/dl/1")!, part: part,
                                    expected: Int64(FakeFilebox.payload.count), configuration: fakeConfig) { _ in }.run()
        }
        #expect(try Data(contentsOf: part) == FakeFilebox.payload)
    }

    @Test func expiredLinkIsReported() async throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        await #expect(throws: RangeDownload.Failure.self) {
            try await withFakeProtocol {
                try await RangeDownload(url: URL(string: "http://filebox.test/dl/expired")!, part: d.appendingPathComponent("x.part"),
                                        expected: 10, configuration: fakeConfig) { _ in }.run()
            }
        }
    }

    @Test func findsGameFilesInsideNestedFolders() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let inner = d.appendingPathComponent("Juego [NSP]/updates")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for f in ["Juego [NSP]/base.nsp", "Juego [NSP]/updates/upd.nsz", "Juego [NSP]/leeme.txt"] {
            FileManager.default.createFile(atPath: d.appendingPathComponent(f).path, contents: Data())
        }
        let found = FileboxDownloads.findGameFiles(in: d).map(\.lastPathComponent)
        #expect(found == ["base.nsp", "upd.nsz"])
    }

    @Test func safeNames() {
        #expect(FileboxDownloads.safeName("a/b:c.zip") == "a_b_c.zip")
        #expect(FileboxDownloads.safeName("../x") == "juego.._x")
    }
}

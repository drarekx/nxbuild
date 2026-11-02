import Foundation
import Testing
@testable import NXBuild

struct QuarantineTests {
    @Test func removesMarkFromWholeBundle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString)/Juego.app")
        let exe = root.appendingPathComponent("Contents/MacOS/nxnative")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: exe)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let value = "0081;00000000;Safari;"
        for p in [root.path, exe.path] {
            #expect(setxattr(p, Quarantine.attribute, value, value.utf8.count, 0, XATTR_NOFOLLOW) == 0)
        }
        #expect(Quarantine.isSet(root.path))
        try await Quarantine.remove(from: root.path)
        #expect(!Quarantine.isSet(root.path))
        #expect(!Quarantine.isSet(exe.path))
    }

    @Test func cleanCopyOfReadOnlyBundleHasNoMark() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString)")
        let app = tmp.appendingPathComponent("src/Juego.app")
        let exe = app.appendingPathComponent("Contents/MacOS/nxnative")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: exe)
        defer {
            _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", tmp.path]).waitUntilExit()
            try? FileManager.default.removeItem(at: tmp)
        }
        let value = "0081;6720f000;Safari;"
        for p in [app.path, exe.path] {
            #expect(setxattr(p, Quarantine.attribute, value, value.utf8.count, 0, XATTR_NOFOLLOW) == 0)
        }
        for p in [exe.path, exe.deletingLastPathComponent().path, app.appendingPathComponent("Contents").path, app.path] {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: p)
        }
        let out = tmp.appendingPathComponent("Applications").path
        let copy = try await Quarantine.cleanCopy(of: app.path, into: out)
        #expect(copy == out + "/Juego.app")
        #expect(!Quarantine.isSet(copy))
        #expect(!Quarantine.isSet(copy + "/Contents/MacOS/nxnative"))
        #expect(FileManager.default.isExecutableFile(atPath: copy + "/Contents/MacOS/nxnative"))
        #expect(Quarantine.isSet(app.path))   // el original no se toca (ni por enlaces duros)
        #expect(Quarantine.isSet(exe.path))
        let second = try await Quarantine.cleanCopy(of: app.path, into: out)
        #expect(second == out + "/Juego 2.app")
    }

    @Test func cancelledCopyLeavesNothing() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString)")
        let app = tmp.appendingPathComponent("src/Juego.app/Contents/Resources")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        for i in 0..<3000 { try Data(count: 4096).write(to: app.appendingPathComponent("f\(i)")) }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("Applications").path
        let src = tmp.appendingPathComponent("src/Juego.app").path
        let seen = Counter()
        let t = Task { try await Quarantine.cleanCopy(of: src, into: out) { p in if p.total > 0 { seen.add() } } }
        try await Task.sleep(for: .milliseconds(30))
        t.cancel()
        await #expect(throws: (any Error).self) { try await t.value }
        #expect(!FileManager.default.fileExists(atPath: out + "/Juego.app"))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    func set(_ v: Int) { lock.lock(); n = v; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

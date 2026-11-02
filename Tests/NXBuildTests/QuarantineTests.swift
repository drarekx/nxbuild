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
        #expect(Quarantine.isSet(app.path))   // el original no se toca
        let second = try await Quarantine.cleanCopy(of: app.path, into: out)
        #expect(second == out + "/Juego 2.app")
    }
}

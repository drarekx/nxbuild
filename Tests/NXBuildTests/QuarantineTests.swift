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
}

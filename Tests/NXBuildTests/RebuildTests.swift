import Foundation
import Testing
@testable import NXBuild

struct RebuildTests {
    private func folder(_ files: [String]) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("Game.app/Contents"), withIntermediateDirectories: true)
        for f in files { try Data("x".utf8).write(to: d.appendingPathComponent(f)) }
        return d
    }

    @Test func aFolderWithTheGamesFilesCanRebuild() throws {
        let d = try folder(["Zelda [0100F2C0115B6000][v0].nsp", "Zelda [0100F2C0115B6800][v720896].nsp"])
        let app = d.appendingPathComponent("Game.app")
        #expect(Rebuild.folder(of: app) != nil)
        #expect(Rebuild.check(app: app, titleID: "0100F2C0115B6000") == nil)
    }

    @Test func filesOfAnotherGameAreRefused() throws {
        let d = try folder(["Mario [0100000000010000][v0].nsp"])
        #expect(Rebuild.check(app: d.appendingPathComponent("Game.app"), titleID: "0100F2C0115B6000") != nil)
    }

    @Test func anAppAloneCannotRebuild() throws {
        let d = try folder([])
        #expect(Rebuild.folder(of: d.appendingPathComponent("Game.app")) == nil)
        #expect(Rebuild.check(app: d.appendingPathComponent("Game.app"), titleID: "0100F2C0115B6000") != nil)
    }
}

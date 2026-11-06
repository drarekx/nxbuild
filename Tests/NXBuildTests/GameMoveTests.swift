import Foundation
import Testing
@testable import NXBuild

struct GameMoveTests {
    private let fm = FileManager.default

    private func tmp() -> URL {
        let d = fm.temporaryDirectory.appendingPathComponent("mv-\(UUID().uuidString)")
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func write(_ u: URL, _ s: String) throws {
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: u)
    }

    /// Carpeta de un juego como la deja una build: app, carpeta de build con extract/ y un NSP con su title ID.
    private func gameFolder(in root: URL, name: String = "Zelda", tid: String = "0100F2C0115B6000") throws -> URL {
        let g = root.appendingPathComponent(name)
        try write(g.appendingPathComponent("\(name).app/Contents/Info.plist"), "plist")
        try write(g.appendingPathComponent("\(name).app/Contents/MacOS/game"), String(repeating: "x", count: 5000))
        try write(g.appendingPathComponent("\(tid)_build/shader/cache/cas.db"), "cache")
        try write(g.appendingPathComponent("\(tid)_build/extract/v0/RomFS.img"), String(repeating: "r", count: 9000))
        try write(g.appendingPathComponent("\(name) [\(tid)][v0].nsp"), "nsp")
        return g
    }

    @Test func aFolderWithOneGameMovesWholeWithoutExtract() async throws {
        let src = tmp(), dst = tmp()
        let g = try gameFolder(in: src)
        let plan = GameMove.plan(app: g.appendingPathComponent("Zelda.app"), titleID: "0100F2C0115B6000")
        #expect(plan.wholeFolder)
        #expect(Set(plan.items.map(\.kind)) == [.app, .build, .game])
        #expect(plan.dropped.count == 1)

        let out = try await GameMove.run(plan, to: dst, forceCopy: true) { _ in }
        #expect(out.standardizedFileURL.path == dst.appendingPathComponent("Zelda").standardizedFileURL.path)
        #expect(fm.fileExists(atPath: out.appendingPathComponent("Zelda.app/Contents/MacOS/game").path))
        #expect(fm.fileExists(atPath: out.appendingPathComponent("0100F2C0115B6000_build/shader/cache/cas.db").path))
        #expect(!fm.fileExists(atPath: out.appendingPathComponent("0100F2C0115B6000_build/extract").path))
        #expect(fm.fileExists(atPath: out.appendingPathComponent("Zelda [0100F2C0115B6000][v0].nsp").path))
        #expect(!fm.fileExists(atPath: g.path))   // la carpeta vieja se ha ido
    }

    @Test func aSharedFolderMovesOnlyThatGame() async throws {
        let src = tmp(), dst = tmp()
        let g = try gameFolder(in: src, name: "Juegos")
        try write(g.appendingPathComponent("Otro.app/Contents/Info.plist"), "plist")
        try write(g.appendingPathComponent("Otro [0100000000010000][v0].nsp"), "nsp")
        let plan = GameMove.plan(app: g.appendingPathComponent("Juegos.app"), titleID: "0100F2C0115B6000")
        #expect(!plan.wholeFolder)
        #expect(!plan.items.contains { $0.name.hasPrefix("Otro") })
        _ = try await GameMove.run(plan, to: dst) { _ in }   // mismo disco: renombrado
        #expect(fm.fileExists(atPath: g.appendingPathComponent("Otro.app").path))
        #expect(fm.fileExists(atPath: dst.appendingPathComponent("Juegos/Juegos.app").path))
        #expect(fm.fileExists(atPath: dst.appendingPathComponent("Juegos/0100F2C0115B6000_build/extract").path))  // mismo disco: viaja
    }

    @Test func linkedFilesTravelAsTheRealFile() async throws {
        let src = tmp(), dst = tmp(), downloads = tmp()
        let g = src.appendingPathComponent("Mario")
        try write(g.appendingPathComponent("Mario.app/Contents/Info.plist"), "plist")
        let real = downloads.appendingPathComponent("Mario [0100000000010000][v0].nsp")
        try write(real, "the real nsp")
        try fm.createSymbolicLink(at: g.appendingPathComponent(real.lastPathComponent), withDestinationURL: real)
        let plan = GameMove.plan(app: g.appendingPathComponent("Mario.app"), titleID: "0100000000010000")
        let out = try await GameMove.run(plan, to: dst, forceCopy: true) { _ in }
        let moved = out.appendingPathComponent(real.lastPathComponent)
        #expect((try? fm.destinationOfSymbolicLink(atPath: moved.path)) == nil)   // ya no es un enlace
        #expect((try? String(contentsOf: moved, encoding: .utf8)) == "the real nsp")
        #expect(!fm.fileExists(atPath: real.path))
    }

    @Test func refusesAnExistingTarget() async throws {
        let src = tmp(), dst = tmp()
        let g = try gameFolder(in: src)
        try write(dst.appendingPathComponent("Zelda/Zelda.app/x"), "x")
        let plan = GameMove.plan(app: g.appendingPathComponent("Zelda.app"), titleID: "0100F2C0115B6000")
        await #expect(throws: GameMove.Failure.self) { _ = try await GameMove.run(plan, to: dst, forceCopy: true) { _ in } }
        #expect(fm.fileExists(atPath: g.appendingPathComponent("Zelda.app").path))
    }
}

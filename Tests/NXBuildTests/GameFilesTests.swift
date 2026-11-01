import Foundation
import Testing
@testable import NXBuild

struct GameFilesTests {
    func file(_ name: String) -> GameFile { GameFile.classify(URL(fileURLWithPath: "/no/existe/" + name)) }

    @Test func rolesAndFamily() {
        let base = file("Zelda [0100F2C0115B6000][v0].nsp")
        let upd = file("Zelda [0100F2C0115B6800][v720896].nsp")
        let dlc = file("Zelda DLC [0100F2C0115B7001][v0].nsp")
        #expect(base.role == .base && upd.role == .update && dlc.role == .dlc)
        #expect(base.appID == 0x0100F2C0115B6000 && upd.appID == base.appID && dlc.appID == base.appID)
        #expect(upd.version == 720896)
        #expect(file("sin etiqueta.nsp").role == .unknown)
    }

    @Test func dropFillsSlots() {
        var sel = GameSelection()
        sel.add([file("A [0100000000010000][v0].nsp"), file("A [0100000000010800][v65536].nsp")])
        // Otro update sustituye al anterior; un DLC se suma; un archivo de otro juego no entra.
        sel.add([file("A [0100000000010800][v131072].nsp"), file("A dlc [0100000000011001][v0].nsp"),
                 file("B [0100000000020000][v0].nsp")])
        #expect(sel.base?.titleID == 0x0100000000010000)
        #expect(sel.updates.map(\.version) == [131072])
        #expect(sel.dlc.count == 1)
        #expect(sel.ignored.map(\.url.lastPathComponent) == ["B [0100000000020000][v0].nsp"])
        #expect(sel.folderName == "A")
    }

    @Test func stagingLinksExactlyTheSelection() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let src1 = tmp.appendingPathComponent("uno"), src2 = tmp.appendingPathComponent("dos"), root = tmp.appendingPathComponent("NX Build")
        try fm.createDirectory(at: src1, withIntermediateDirectories: true)
        try fm.createDirectory(at: src2, withIntermediateDirectories: true)
        let b = src1.appendingPathComponent("Juego [0100000000010000][v0].nsp")
        let u1 = src2.appendingPathComponent("Juego [0100000000010800][v65536].nsp")
        let u2 = src2.appendingPathComponent("Juego [0100000000010800][v131072].nsp")
        for f in [b, u1, u2] { try Data("x".utf8).write(to: f) }

        var sel = GameSelection()
        sel.add([GameFile.classify(b), GameFile.classify(u1)])
        let dir = try GameStaging.stage(sel, root: root)
        #expect(dir.lastPathComponent == "Juego")
        // Lo que deja el script (la carpeta de build, la app) no se toca.
        try fm.createDirectory(at: dir.appendingPathComponent("0100000000010000_build"), withIntermediateDirectories: true)

        sel.add([GameFile.classify(u2)])
        _ = try GameStaging.stage(sel, root: root)
        let names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["0100000000010000_build", b.lastPathComponent, u2.lastPathComponent].sorted())
        #expect(try fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(u2.lastPathComponent).path) == u2.path)

        let scanned = GameStaging.scan(dir)
        #expect(scanned.base?.url == b.resolvingSymlinksInPath())
        #expect(scanned.updates.map(\.version) == [131072])
        #expect(GameStaging.isStaged(dir, root: root))
    }

    /// Con los NSP reales de ~/dev/switch, si están: el ticket del PFS0 da el title ID.
    @Test func realFiles() throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/dev/switch/Final Fantasy Resonance [NSP]")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let sel = GameStaging.scan(dir)
        print("Real:", sel.files.map { "\($0.label): \($0.url.lastPathComponent) ticket=\(GameFile.ticketTitleID($0.url).map { String(format: "%016llX", $0) } ?? "-")" })
        #expect(sel.base != nil)
        #expect(sel.updates.count == 1)
        #expect(sel.updates.first?.appID == sel.base?.appID)
    }
}

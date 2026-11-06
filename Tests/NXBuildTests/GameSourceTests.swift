import Foundation
import Testing
@testable import NXBuild

struct GameSourceTests {
    private func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("gs-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Un main.npdm mínimo: META, el offset y tamaño de ACI0 en 0x70, y el program ID en ACI0+0x10.
    private func npdm(_ tid: UInt64) -> Data {
        var d = Data(count: 0x100)
        d.replaceSubrange(0..<4, with: Data("META".utf8))
        d.replaceSubrange(0x70..<0x74, with: withUnsafeBytes(of: UInt32(0x80).littleEndian) { Data($0) })
        d.replaceSubrange(0x74..<0x78, with: withUnsafeBytes(of: UInt32(0x40).littleEndian) { Data($0) })
        d.replaceSubrange(0x80..<0x84, with: Data("ACI0".utf8))
        d.replaceSubrange(0x90..<0x98, with: withUnsafeBytes(of: tid.littleEndian) { Data($0) })
        return d
    }

    private func mkdump(_ dir: URL, _ path: String, tid: UInt64) throws {
        let fm = FileManager.default
        let v = dir.appendingPathComponent(path)
        try fm.createDirectory(at: v.appendingPathComponent("exefs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: v.appendingPathComponent("romfs"), withIntermediateDirectories: true)
        try npdm(tid).write(to: v.appendingPathComponent("exefs/main.npdm"))
    }

    @Test func dumpWithBaseUpdateAndDLC() throws {
        let d = tmp()
        try mkdump(d, "base", tid: 0x040074A01BF12000)
        try mkdump(d, "updates/458752", tid: 0x040074A01BF12000)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("dlc/040074A01BF13001/0/romfs"), withIntermediateDirectories: true)
        let s = GameSource.detect(d)
        #expect(s == .dump(titleID: 0x040074A01BF12000, updates: [458752], dlc: 1))
        #expect(s?.needsKeys == false)
        #expect(GameSource.isSwitch2(s?.titleID))
    }

    @Test func dumpOfAnUpdateAlone() throws {
        let d = tmp()
        try mkdump(d, "updates/131072", tid: 0x04007EF01F8AE000)
        #expect(GameSource.detect(d) == .dump(titleID: 0x04007EF01F8AE000, updates: [131072], dlc: 0))
    }

    @Test func nupNeedsNoKeysAndTwoAreAProblem() throws {
        let d = tmp()
        try Data("NUP1....".utf8).write(to: d.appendingPathComponent("Star Fox [0400E88025B1A000].nup"))
        let s = GameSource.detect(d)
        #expect(s?.needsKeys == false)
        #expect(s?.titleID == 0x0400E88025B1A000)
        try Data("NUP1".utf8).write(to: d.appendingPathComponent("other.nup"))
        if case .problem = GameSource.detect(d) {} else { Issue.record("dos NUP deberían ser un problema") }
    }

    @Test func aFileNamedNupWithoutTheMagicIsNotOne() throws {
        let d = tmp()
        try Data("PFS0".utf8).write(to: d.appendingPathComponent("fake.nup"))
        #expect(GameSource.detect(d) == nil)
    }

    @Test func packagesWinOverEverythingElse() throws {
        let d = tmp()
        try mkdump(d, "base", tid: 0x0100000000010000)
        try Data("PFS0".utf8).write(to: d.appendingPathComponent("game.nsp"))
        #expect(GameSource.detect(d) == .packages)
        #expect(GameSource.detect(d)?.needsKeys == true)
    }
}

struct BuildWarningsTests {
    @Test func keysOlderThanTheGameNamesKeyAndFirmware() {
        let line = "[RED] nx_extract: game.nsp: prod.keys has no master_key_13 (master key 13, which came with firmware 19.0.0): the keys are older than the game; dump prod.keys again from a console on firmware 19.0.0 or later"
        let f = BuildFailureClassifier.classify(log: [line], inputs: .init())
        #expect(f.kind == .keysOld)
        #expect(f.next.contains("master_key_13"))
        #expect(f.next.contains("firmware 19.0.0"))
        #expect(f.actions.contains(.chooseKeys))
    }

    @Test(arguments: [
        ("[RED] pso_offline: 0.4 GB free on the volume of /x/pso/work, metal-tt needs about 3 GB for 33858 bases: free some space and run again", "3"),
        ("[RED] pso_offline: 0.7 GB free before merging; need at least 2.5 GB", "2.5"),
    ])
    func psoDiskFull(_ line: String, _ gb: String) {
        let f = BuildFailureClassifier.classify(log: [line], inputs: .init())
        #expect(f.kind == .diskFull)
        #expect(f.next.contains("\(gb) GB"))
    }

    @Test func psoFailedOutOfDisk() {
        let line = "[RED] pso_offline: metal-tt failed for applegpu_g18p (exit 1) (0.3 GB free on the volume of /x when it failed: likely out of disk space): compiler output"
        #expect(BuildFailureClassifier.classify(log: [line], inputs: .init()).kind == .diskFull)
    }

    @Test func warningNoteForPipelineArchiveWithoutSpace() {
        #expect(BuildRunner.warningNote(["[RED] pso_offline: 0.7 GB free before merging; need at least 2.5 GB"])?.contains("2.5 GB") == true)
        #expect(BuildRunner.warningNote(["[RED] something else"]) == nil)
    }
}

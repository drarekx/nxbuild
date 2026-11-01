import Foundation
import Testing
@testable import NXBuild

struct KeyCheckTests {
    /// IEEE 1619 (XTS-AES-128), vector 1: claves a cero, sector 0, 32 bytes a cero.
    @Test func xtsVector() {
        let ct: [UInt8] = hex("917cf69ebd68b2ec9b9fe9a3eadda692cd43d2f59598ed858c02c2652fbf922e")
        var sector = ct + [UInt8](repeating: 0, count: 0x200 - ct.count)
        sector = KeyCheck.decryptHeader(sector, key: [UInt8](repeating: 0, count: 32))
        #expect(Array(sector[0..<32]) == [UInt8](repeating: 0, count: 32))
    }

    @Test func neededKeyNames() {
        var h = [UInt8](repeating: 0, count: 0x400)
        h[0x206] = 2; h[0x220] = 0x11; h[0x207] = 0          // generación 0x11 → índice 0x10, área application
        #expect(KeyCheck.neededKeys(header: h) == [.init(name: "key_area_key_application_10", master: "master_key_10")])
        h[0x230] = 1                                          // con rights ID: clave de título
        #expect(KeyCheck.neededKeys(header: h) == [.init(name: "titlekek_10", master: "master_key_10")])
        h = [UInt8](repeating: 0, count: 0x400)               // generación 0 y 1 son la misma (índice 0)
        #expect(KeyCheck.neededKeys(header: h).first?.name == "key_area_key_application_00")
    }

    @Test func keysWithoutHeaderKey() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".keys")
        try "master_key_00 = 00112233445566778899aabbccddeeff\n".write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        let r = KeyCheck.run(folder: FileManager.default.temporaryDirectory, keysFile: f)
        #expect(r.verdict == .noHeaderKey)
    }

    /// Con los archivos reales de ~/dev/switch, si están. Solo se imprime el veredicto.
    @Test func realGameFolder() throws {
        let root = NSHomeDirectory() + "/dev/switch"
        let keys = URL(fileURLWithPath: root + "/prod/prod.keys")
        let folder = URL(fileURLWithPath: root + "/Final Fantasy Resonance [NSP]")
        guard FileManager.default.fileExists(atPath: keys.path), FileManager.default.fileExists(atPath: folder.path) else { return }
        let r = KeyCheck.run(folder: folder, keysFile: keys)
        print("KeyCheck real:", r.message)
        #expect(!r.isProblem)
    }

    /// El mismo juego con unas prod.keys sin claves de área ni master_key: tiene que decir cuáles faltan.
    @Test func realGameFolderMissingKeys() throws {
        let root = NSHomeDirectory() + "/dev/switch"
        let keys = URL(fileURLWithPath: root + "/prod/prod.keys")
        let folder = URL(fileURLWithPath: root + "/Final Fantasy Resonance [NSP]")
        guard FileManager.default.fileExists(atPath: keys.path), FileManager.default.fileExists(atPath: folder.path) else { return }
        let kept = try String(contentsOf: keys, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("key_area_key_") && !$0.hasPrefix("master_key_") && !$0.hasPrefix("titlekek_") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".keys")
        try kept.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = KeyCheck.run(folder: folder, keysFile: tmp)
        print("KeyCheck sin claves:", r.message)
        guard case .missing(let names, _) = r.verdict else { Issue.record("esperaba .missing, salió \(r.verdict)"); return }
        #expect(!names.isEmpty)
    }
}

private func hex(_ s: String) -> [UInt8] {
    stride(from: 0, to: s.count, by: 2).map { i in
        let a = s.index(s.startIndex, offsetBy: i)
        return UInt8(s[a..<s.index(a, offsetBy: 2)], radix: 16)!
    }
}

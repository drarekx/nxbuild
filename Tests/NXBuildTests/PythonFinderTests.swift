import Foundation
import Testing
@testable import NXBuild

struct PythonFinderTests {
    /// Un «python» falso: un script que responde al sondeo como un Python con todos los módulos.
    func fakePython(at path: String, ver: [Int], machine: String = "arm64", venv: Bool = false, capstone: Int = 5) throws {
        let json = #"{"ver": [\#(ver.map(String.init).joined(separator: ", "))], "machine": "\#(machine)", "venv": \#(venv), "mods": {"lz4": true, "fonttools": true, "zstd": true, "capstone": \#(capstone), "nsz": true, "zbic": false}}"#
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "#!/bin/sh\necho '\(json)'\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    @Test func findsUvInterpreterWhenConfiguredIsGone() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let uv = home + "/.local/share/uv/python/cpython-3.13.2-macos-aarch64-none/bin/python3"
        let old = home + "/.local/share/uv/python/cpython-3.12.1-macos-aarch64-none/bin/python3"
        try fakePython(at: uv, ver: [3, 13, 2])
        try fakePython(at: old, ver: [3, 12, 1], capstone: 6)

        let c = PythonFinder.candidates(configured: "/no/existe/python3", venv: home + "/venv/bin/python3", home: home, env: [:])
        #expect(c.prefix(2) == [uv, old])                  // la más nueva primero, la del Ajuste no existe
        let probes = c.prefix(2).map(PythonFinder.probe)
        #expect(probes[0].usable)
        #expect(!probes[1].usable && probes[1].missing == ["capstone 5.x (hay 6.x)"])
        #expect(probes[0].optionalMissing == ["zbic"])
    }

    @Test func bestBasePrefersSupportedVersions() {
        func p(_ v: [Int], venv: Bool = false, machine: String = "arm64") -> PythonFinder.Probe {
            PythonFinder.Probe(path: "/x/\(v)", runs: true, version: v, machine: machine, isVenv: venv)
        }
        #expect(PythonFinder.bestBase([p([3, 15, 0]), p([3, 13, 1]), p([3, 14, 2], venv: true), p([3, 11, 0])])?.version == [3, 13, 1])
        #expect(PythonFinder.bestBase([p([3, 15, 0]), p([3, 12, 0], machine: "x86_64")])?.version == [3, 15, 0])
        #expect(PythonFinder.bestBase([p([3, 9, 6])]) == nil)
    }

    /// Los Python reales de este Mac: solo se prueban, no se cambia nada.
    @Test func realMachine() {
        let c = PythonFinder.candidates(configured: "/opt/homebrew/bin/python3.14", venv: Dependencies.venvDir.path + "/bin/python3")
        let probes = c.map(PythonFinder.probe)
        for p in probes { print("probe:", p.path, "→", p.verdict) }
        #expect(!probes.isEmpty)
        #expect(probes.contains { $0.modernARM })
    }
}

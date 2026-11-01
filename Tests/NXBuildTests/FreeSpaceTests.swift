import Foundation
import Testing
@testable import NXBuild

struct FreeSpaceTests {
    func makeBuildDir() throws -> (root: URL, build: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let build = root.appendingPathComponent("0100000000010000_build")
        for d in ["extract/romfs", "aoc", "shader", "pso", "ipa", "app", "tmp", "tools", "font", "patched_v0",
                  "logs", "profile/0100000000010000", "run/save", "nsp"] {
            try fm.createDirectory(at: build.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        for f in ["extract/romfs/data.bin", "shader/cache.bin", "logs/extract.log", "profile/0100000000010000/game.py",
                  "run/save/slot0", "nsp/juego.nsp", "patched_v0.key", "patched_v0/main"] {
            try Data(repeating: 7, count: 10_000).write(to: build.appendingPathComponent(f))
        }
        return (root, build)
    }

    @Test func groupsAndDelete() throws {
        let (root, build) = try makeBuildDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FreeSpace.isBuildDir(build))
        #expect(FreeSpace.buildDirs(for: root).map(\.path) == [build.resolvingSymlinksInPath().path])

        let groups = FreeSpace.groups(in: build)
        #expect(groups.map(\.id) == ["extract", "shader", "package", "code"])
        #expect(groups.first { $0.id == "extract" }!.bytes > 0)
        #expect(groups.first { $0.id == "code" }!.paths.map(\.lastPathComponent).contains("patched_v0.key"))

        _ = try FreeSpace.delete(groups, in: build)
        let left = try FileManager.default.contentsOfDirectory(atPath: build.path).sorted()
        #expect(left == ["logs", "nsp", "profile", "run"])
        #expect(FileManager.default.fileExists(atPath: build.appendingPathComponent("run/save/slot0").path))
    }

    @Test func onlySelectedGroups() throws {
        let (root, build) = try makeBuildDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let shader = FreeSpace.groups(in: build).filter { $0.id == "shader" }
        _ = try FreeSpace.delete(shader, in: build)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: build.path))
        #expect(!left.contains("shader") && !left.contains("pso"))
        #expect(left.contains("extract") && left.contains("ipa"))
    }

    @Test func plainFoldersAreNotBuildDirs() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_build")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(!FreeSpace.isBuildDir(tmp))                         // se llama _build pero no tiene nada del script
        #expect(!FreeSpace.isBuildDir(URL(fileURLWithPath: NSHomeDirectory())))
    }

    /// La carpeta real de Octopath, si está: solo se mide, no se borra nada.
    @Test func realBuildDirIsMeasured() {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/dev/switch/games/010057D006492000_build")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let g = FreeSpace.groups(in: dir)
        print("Real:", g.map { "\($0.id)=\(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))" })
        #expect(g.contains { $0.id == "extract" && $0.bytes > 0 })
        #expect(!g.flatMap(\.paths).contains { ["logs", "profile", "run"].contains($0.lastPathComponent) })
    }
}

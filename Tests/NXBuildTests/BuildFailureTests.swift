import Foundation
import Testing
@testable import NXBuild

/// Mensajes reales del script (o de las herramientas que lanza) → el tipo de fallo que debe salir.
struct BuildFailureTests {
    static let cases: [(String, BuildFailure.Kind)] = [
        ("[RED] this Python (/usr/local/bin/python3) is an Intel one running under Rosetta, and the tools it starts would run as Intel code too", .rosetta),
        ("[RED] the shader translator does not run (No .NET runtime): it needs the .NET 10 runtime", .translator),
        ("[RED] the current Python (/x/python3) is missing modules: lz4.block, capstone", .pythonModules),
        ("[RED] Capstone 6.0.0 is unsupported; the rewriter requires Capstone 5.x. Run: pip install", .pythonModules),
        ("[RED] main: ZBIC (zstd) segments need the zbic package (python3 -m pip install zbic)", .pythonModules),
        ("[RED] the iOS SDK is not installed: install the iOS platform in Xcode", .iosSDK),
        ("[RED] the selected developer folder is the Command Line Tools (/Library/Developer/CommandLineTools)", .cltSelected),
        ("[RED] the Metal compiler does not run (error): install it with xcodebuild -downloadComponent MetalToolchain", .metalMissing),
        ("[RED] tools not found: xcodegen (brew install xcodegen)", .tools),
        ("[RED] this Mac's Metal compiler is not the one the shaders were tested with (dm/gfx/tools/dmsh_chain.lock)", .otherMetal),
        ("[RED] 12 shaders that translated in b-41 fail in b-42: a change to the translation chain broke them", .shaderRegression),
        ("[RED] Zelda (0100F2C0115B6000) is a 32-bit ARM program (main.npdm: the 64-bit instruction flag is clear)", .a32Program),
        ("[RED] no such file: /Users/x/prod.keys", .keysMissing),
        ("LibHac.Common.Keys.MissingKeyException: Unable to decrypt NCA section.", .keysOld),
        ("[RED] more than one game in the folder: 0100A, 0100B; keep one game per folder", .severalGames),
        ("[RED] no NSP with a readable title ID in /Users/x/juegos", .noGame),
        ("[RED] no NSP for update v327680 (the game profile needs these versions: v327680)", .updateMissing),
        ("[RED] less than 40 GB free on the volume of /Users/x/juego/0100_build", .diskFull),
        ("codesign: resource fork, Finder information, or similar detritus not allowed", .cloudFolder),
        ("[RED] the shader split found no shaders in main or the RomFS", .unsupportedShaders),
        ("[RED] the game has no ja (Japanese); its languages: en, fr (--language / LANGUAGE)", .language),
        ("[RED] something nobody planned for", .unknown),
    ]

    @Test(arguments: cases)
    func classifies(_ line: String, _ kind: BuildFailure.Kind) {
        let f = BuildFailureClassifier.classify(log: ["[1/5] extract", line], inputs: .init())
        #expect(f.kind == kind)
    }

    @Test func diskFullNamesTheGigabytes() {
        let f = BuildFailureClassifier.classify(log: ["[RED] less than 40 GB free on the volume of /x"], inputs: .init())
        #expect(f.next.contains("40 GB"))
    }

    /// NSP dañado: en pantalla solo sale «nx_extract exit code 3»; el motivo está en el log citado.
    @Test func readsTheCitedLog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("extract.log")
        try """
        reading base
        [RED] hash check failed: /romfs/Model/a.bfres
        [RED] the NSP is damaged: 1 files fail the NCA's hash check (an incomplete copy or a broken download); copy or download it again
        """.write(to: log, atomically: true, encoding: .utf8)
        let f = BuildFailureClassifier.classify(log: ["[RED] nx_extract exit code 3 (full output: \(log.path))"], inputs: .init())
        #expect(f.kind == .damagedNSP)
        #expect(f.logFile == log)
        #expect(f.actions == [.retry(flag: "--allow-damaged")])
    }

    @Test func missingDriveWinsOverTheLog() {
        let f = BuildFailureClassifier.classify(log: ["[RED] not a folder: /Volumes/NoExiste123/juego"],
                                                inputs: .init(nspDir: "/Volumes/NoExiste123/juego"))
        #expect(f.kind == .driveMissing)
        #expect(f.next.contains("NoExiste123"))
    }

    @Test func unknownShowsLastRedLine() {
        let f = BuildFailureClassifier.classify(log: ["[RED] primero", "algo", "[RED] último"], inputs: .init())
        #expect(f.kind == .unknown)
        #expect(f.evidence == "último")
    }

    /// Cada patrón tiene que seguir existiendo en el código de nxnative: si un sync cambia el texto de un mensaje,
    /// este test falla en vez de dejar el aviso en «no reconozco el error».
    @Test func patternsStillInEngine() throws {
        let repo = NSHomeDirectory() + "/dev/switch/nxnative"
        let sources = ["scripts/build_ipa_from_nsp.py", "dm/tools/nx_extract/Program.cs", "dm/gfx/tools/own_compilers.py", "dm/tools/nso.py"]
        let texts = sources.compactMap { try? String(contentsOfFile: repo + "/" + $0, encoding: .utf8) }
        try #require(texts.count == sources.count, "no encuentro nxnative en \(repo)")
        let engine = texts.joined(separator: "\n").replacingOccurrences(of: "\\'", with: "'")
        // Mensajes que no salen del código del repositorio (LibHac, codesign, el sistema).
        let external: Set<BuildFailure.Kind> = [.keysOld, .cloudFolder]
        for row in BuildFailureClassifier.table where !external.contains(row.kind) {
            let alternatives = row.pattern.split(separator: "|").map(String.init)
            let found = alternatives.contains { alt in
                // Parte literal más larga del patrón (hasta el primer metacarácter).
                let lit = alt.replacingOccurrences(of: "(?m)^\\[RED\\] ", with: "")
                    .split(whereSeparator: { "[]()+*?.\\^$".contains($0) }).map(String.init).max { $0.count < $1.count } ?? alt
                return engine.contains(lit)
            }
            #expect(found, "\(row.kind): ningún fragmento de «\(row.pattern)» está en nxnative")
        }
    }
}

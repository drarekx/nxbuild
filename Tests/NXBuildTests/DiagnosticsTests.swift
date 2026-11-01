import Foundation
import Testing
@testable import NXBuild

struct DiagnosticsTests {
    @Test func sanitizeHidesKeysAndHome() {
        let s = Diagnostics.sanitize("""
        header_key = 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
          master_key_15 = 00112233445566778899aabbccddeeff
        ticket 0100606026F12000000000000000000a.tik
        path \(NSHomeDirectory())/dev/switch/prod/prod.keys
        title 0100606026F12000 commit cd859c38
        """)
        #expect(!s.contains("00112233445566778899aabbccddeeff"))
        #expect(s.contains("header_key = <redacted>"))
        #expect(s.contains("master_key_15 = <redacted>"))
        #expect(s.contains("ticket <redacted>.tik"))
        #expect(s.contains("~/dev/switch/prod/prod.keys") && !s.contains(NSHomeDirectory()))
        #expect(s.contains("0100606026F12000") && s.contains("cd859c38"))   // title ID y commit corto se quedan
    }

    /// Informe de este Mac: no debe llevar la carpeta de usuario ni la clave de ejemplo del log.
    @Test func realReport() {
        let input = Diagnostics.Input(
            repoPath: NSHomeDirectory() + "/dev/switch/nxnative", pythonPath: "/opt/homebrew/bin/python3.14",
            deps: [("Xcode", "ok", "Xcode 27.2")], game: NSHomeDirectory() + "/dev/switch/games",
            gameFiles: ["Juego base: A [0100000000010000][v0].nsp"], keyCheck: "Las claves abren los 2 archivos del juego",
            platform: "mac-app", phase: "failed (exit 1)", failure: "damagedNSP — NSP dañado",
            command: "python3 build_ipa_from_nsp.py " + NSHomeDirectory() + "/x -k " + NSHomeDirectory() + "/prod.keys",
            logTail: ["[1/5] extract", "header_key = ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100", "[RED] nx_extract exit code 3"])
        let r = Diagnostics.report(input)
        print(r)
        #expect(!r.contains(NSHomeDirectory()))
        #expect(!r.contains("ffeeddccbbaa9988"))
        #expect(r.contains("### Toolchain") && r.contains("Metal macOS"))
    }
}

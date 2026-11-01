import Foundation
import Testing
@testable import NXBuild

struct LibraryTests {
    static let octopath = NSHomeDirectory() + "/dev/switch/games/OCTOPATH TRAVELER.app"
    var haveOctopath: Bool { FileManager.default.fileExists(atPath: Self.octopath) }

    @Test func readsBuiltApp() throws {
        guard haveOctopath else { return }
        let g = try #require(LibraryGame.read(URL(fileURLWithPath: Self.octopath)))
        #expect(g.titleID == "010057D006492000")
        #expect(g.bundleID == "org.nxnative.010057d006492000")
        #expect(g.name == "OCTOPATH TRAVELER")
        #expect(g.hasLaunchSettings)
        #expect(g.logURL.lastPathComponent == "010057D006492000.log")
    }

    @Test func scanFindsGamesAndSkipsBuildFolders() {
        guard haveOctopath else { return }
        let found = GameLibrary.scan([NSHomeDirectory() + "/dev/switch"])
        print("Biblioteca:", found.map { "\($0.name) (\($0.titleID))" })
        #expect(found.contains { $0.titleID == "010057D006492000" })
        #expect(!found.contains { $0.path.contains("_build/") })
        #expect(!found.contains { $0.name == "NX Build" })            // nuestra propia app no es un juego
    }

    @Test func decodesLauncherJSON() throws {
        guard haveOctopath else { return }
        let f = try #require(LaunchSettingsFile.load(app: URL(fileURLWithPath: Self.octopath)))
        let byEnv = Dictionary(uniqueKeysWithValues: f.settings.map { ($0.env, $0) })
        #expect(byEnv["DM_OPMODE"]?.kind == "choice" && byEnv["DM_OPMODE"]?.isBasic == true)
        let gain = try #require(byEnv["DM_RUMBLE_GAIN"])
        #expect(gain.needs == "DM_RUMBLE=1" && gain.max == 3.0)
        #expect(gain.accepts("2.5") && !gain.accepts("4") && gain.isDefault("1"))
        #expect(gain.format(1.5) == "1.5" && gain.format(2) == "2.0")
        #expect(byEnv["DM_RUMBLE"]?.accepts("0") == true && byEnv["DM_RUMBLE"]?.accepts("2") == false)
    }

    /// Las opciones que ya tienes guardadas en Octopath (solo lectura).
    @Test func readsExistingSavedChoices() throws {
        guard haveOctopath else { return }
        let f = try #require(LaunchSettingsFile.load(app: URL(fileURLWithPath: Self.octopath)))
        let saved = SavedChoices(bundleID: "org.nxnative.010057d006492000")
        for s in f.settings where saved.value(s.env) != nil { print("guardado:", s.env, "=", saved.value(s.env)!) }
        print("cambiadas:", saved.changedCount(f.settings))
    }

    /// Escritura en un dominio de prueba: el valor por defecto borra la clave; otro valor la guarda; reset las borra.
    @Test func writesOnlyNonDefaults() throws {
        let json = #"{"schema":1,"game":"0100000000010000","settings":[{"env":"DM_X","kind":"toggle","label":"X","default":"0","on":"1","off":"0"},{"env":"DM_Y","kind":"range","label":"Y","default":"1.0","min":0,"max":2,"step":0.5,"needs":"DM_X=1"}]}"#
        let f = try JSONDecoder().decode(LaunchSettingsFile.self, from: Data(json.utf8))
        let domain = "org.nxnative.nxbuildtest\(Int.random(in: 1000...9999))"
        let saved = SavedChoices(bundleID: domain)
        defer { saved.reset(f.settings) }
        let x = f.settings[0], y = f.settings[1]
        #expect(!saved.visible(y, in: f.settings))
        saved.set(x, "1")
        #expect(saved.value("DM_X") == "1" && saved.visible(y, in: f.settings))
        saved.set(y, "1")                                  // = 1.0, el por defecto: no se guarda
        #expect(saved.value("DM_Y") == nil)
        saved.set(y, "1.5")
        #expect(saved.effective(y) == "1.5" && saved.changedCount(f.settings) == 2)
        saved.set(x, "0")
        #expect(saved.value("DM_X") == nil)
        saved.reset(f.settings)
        #expect(saved.changedCount(f.settings) == 0)
    }
}

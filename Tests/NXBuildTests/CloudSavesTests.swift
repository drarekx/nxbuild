import Testing
@testable import NXBuild

@Suite struct CloudSavesTests {
    let tid = "01001F5010DFA000"

    @Test func fileInSharedFolder() {
        #expect(CloudSaves.file(folder: "/c/Saves/", titleID: tid) == "/c/Saves/01001F5010DFA000/save.dmsync")
    }

    @Test func gamesOwnFolderAnyCase() {
        #expect(CloudSaves.file(folder: "/c/Saves/01001f5010dfa000", titleID: tid) == "/c/Saves/01001f5010dfa000/save.dmsync")
        #expect(CloudSaves.shared(folder: "/c/Saves/01001f5010dfa000", titleID: tid) == "/c/Saves")
        #expect(CloudSaves.shared(folder: "/c/Saves", titleID: tid) == "/c/Saves")
    }

    @Test func roundTripPreference() {
        let c = CloudSaves(bundleID: "org.nxnative.test.cloudsaves", titleID: tid)
        c.set("/tmp/x"); #expect(c.folder == "/tmp/x")
        c.set(nil); #expect(c.folder == nil)
    }
}

@Suite struct UpdaterTests {
    @Test func comparesVersionsNumerically() {
        #expect(Updater.compare("1.10.0", "1.9.2") == .orderedDescending)
        #expect(Updater.compare("1.0", "1.0.0") == .orderedSame)
        #expect(Updater.compare("0.9", "1.0") == .orderedAscending)
    }
}

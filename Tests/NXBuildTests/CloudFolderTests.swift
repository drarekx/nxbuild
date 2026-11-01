import Foundation
import Testing
@testable import NXBuild

/// Solo rutas de ejemplo: no se lee ninguna carpeta sincronizada de verdad.
struct CloudFolderTests {
    let home = "/Users/ejemplo"

    @Test func mobileDocumentsIsICloudDrive() {
        #expect(CloudFolder.service(of: home + "/Library/Mobile Documents/com~apple~CloudDocs/Juegos/Zelda", home: home) == "iCloud Drive")
    }

    @Test func cloudStorageNamesTheService() {
        #expect(CloudFolder.service(of: home + "/Library/CloudStorage/Dropbox/Juegos", home: home) == "Dropbox")
        #expect(CloudFolder.service(of: home + "/Library/CloudStorage/OneDrive-Personal/Juegos", home: home) == "OneDrive")
        #expect(CloudFolder.service(of: home + "/Library/CloudStorage/GoogleDrive-yo@example.com/Mi unidad", home: home) == "GoogleDrive")
    }

    @Test func localFoldersAreNotCloud() {
        #expect(CloudFolder.service(of: home + "/dev/switch/games", home: home) == nil)
        #expect(CloudFolder.service(of: "/Volumes/Download/juegos", home: home) == nil)
        #expect(CloudFolder.service(of: home + "/Library/Application Support/x", home: home) == nil)
    }

    @Test func localWorkDirIsOutsideTheCloud() {
        let src = URL(fileURLWithPath: home + "/Library/Mobile Documents/com~apple~CloudDocs/Zelda TOTK")
        let w = CloudFolder.localWorkDir(for: src, home: home)
        #expect(w.path == home + "/NX Build/Zelda TOTK/build")
        #expect(CloudFolder.service(of: w.path, home: home) == nil)
    }

    @Test func workDirGoesToTheScript() {
        var o = BuildOptions()
        o.workDir = "/Users/ejemplo/NX Build/Zelda/build"
        let a = o.arguments(platform: .macApp)
        #expect(a.firstIndex(of: "--work-dir").map { a[$0 + 1] } == "/Users/ejemplo/NX Build/Zelda/build")
    }

    /// Una carpeta local de verdad (la del proyecto) no sale como nube.
    @Test func realLocalFolder() {
        #expect(CloudFolder.check(URL(fileURLWithPath: NSHomeDirectory() + "/dev/switch")) == nil)
    }
}

import Foundation

/// Carpetas que sincroniza un servicio en la nube. El servicio añade atributos extendidos a los archivos y codesign los
/// rechaza («resource fork, Finder information, or similar detritus not allowed»): una build ahí falla en el último paso,
/// a veces tras una hora. Además, con «Optimizar almacenamiento» los NSP pueden estar solo en la nube.
enum CloudFolder {
    struct Info: Equatable {
        var service: String
        var notDownloaded: [String] = []
    }

    /// nil si la carpeta no está en la nube.
    static func check(_ folder: URL, home: String = NSHomeDirectory()) -> Info? {
        guard let service = service(of: folder.standardizedFileURL.path, home: home) ?? ubiquitousAncestor(folder, home: home) else {
            return nil
        }
        return Info(service: service, notDownloaded: notDownloaded(in: folder))
    }

    /// Por la ruta: ~/Library/Mobile Documents (iCloud Drive) y ~/Library/CloudStorage/<Servicio-cuenta> (File Provider:
    /// Dropbox, OneDrive, Google Drive, Box…).
    static func service(of path: String, home: String) -> String? {
        let lib = (home as NSString).appendingPathComponent("Library")
        if path.hasPrefix(lib + "/Mobile Documents") { return "iCloud Drive" }
        let cs = lib + "/CloudStorage/"
        if path.hasPrefix(cs) {
            let first = path.dropFirst(cs.count).split(separator: "/").first.map(String.init) ?? ""
            let name = first.split(separator: "-").first.map(String.init) ?? first
            return name.isEmpty ? "almacenamiento en la nube" : name
        }
        return nil
    }

    /// Escritorio y Documentos sincronizados con iCloud (o cualquier carpeta que el sistema marque como ubicua):
    /// se mira la carpeta y sus padres hasta la carpeta de usuario.
    private static func ubiquitousAncestor(_ folder: URL, home: String) -> String? {
        var u = folder.standardizedFileURL
        while u.path.hasPrefix(home + "/") {
            if (try? u.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
                return "iCloud Drive (\(u.lastPathComponent))"
            }
            u.deleteLastPathComponent()
        }
        return nil
    }

    /// Juegos de la carpeta que no están descargados del todo.
    private static func notDownloaded(in folder: URL) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey])) ?? []
        return items.filter { ["nsp", "nsz", "xci", "xcz"].contains($0.pathExtension.lowercased()) }.filter {
            guard let st = (try? $0.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
            else { return false }
            return st != .current
        }.map(\.lastPathComponent)
    }

    /// Carpeta de build local para un juego: ~/NX Build/<nombre de la carpeta del juego>/build. La app o IPA queda en
    /// ~/NX Build/<nombre>/ (el script la pone junto a --work-dir).
    static func localWorkDir(for nspDir: URL, home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("NX Build")
            .appendingPathComponent(nspDir.lastPathComponent).appendingPathComponent("build")
    }
}

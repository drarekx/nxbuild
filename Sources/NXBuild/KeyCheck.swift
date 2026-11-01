import Foundation
import CommonCrypto

/// Comprueba antes de construir que prod.keys abre los archivos del juego, sin esperar a que falle la extracción.
///
/// De cada NSP/NSZ se lee la tabla PFS0 y los primeros 0x400 bytes de cada NCA (un NCZ guarda la cabecera sin comprimir).
/// La cabecera va cifrada con header_key (AES-128-XTS, sectores de 0x200, número de sector en big-endian: la variante de
/// Nintendo). Descifrada, dice la generación de clave que necesita el contenido y si usa clave de título (rights ID).
/// Los valores de las claves nunca se muestran ni se guardan.
struct KeyCheck: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        case ok(files: Int)
        case noHeaderKey                       // prod.keys sin header_key
        case headerKeyWrong(file: String)      // header_key no descifra una cabecera
        case missing(keys: [String], files: [String])
        case unreadable(String)
        case notChecked(String)                // XCI o carpeta sin NSP/NSZ
    }
    var verdict: Verdict
    var skipped: [String] = []                 // XCI y similares, que no se pueden comprobar así

    var isProblem: Bool {
        switch verdict {
        case .noHeaderKey, .headerKeyWrong, .missing, .unreadable: true
        default: false
        }
    }

    var isOK: Bool { if case .ok = verdict { true } else { false } }

    var message: String {
        let extra = skipped.isEmpty ? "" : " (sin comprobar: \(skipped.joined(separator: ", ")))"
        switch verdict {
        case .ok(let n):
            return "Las claves abren \(n == 1 ? "el archivo" : "los \(n) archivos") del juego" + extra
        case .noHeaderKey:
            return "Este prod.keys no tiene header_key: no es un prod.keys completo"
        case .headerKeyWrong(let f):
            return "header_key no abre \(f): prod.keys equivocado o archivo dañado"
        case .missing(let keys, let files):
            return "Faltan \(keys.joined(separator: ", ")) para \(files.joined(separator: ", ")): saca unas prod.keys de un firmware más reciente"
        case .unreadable(let why):
            return "No se pudo comprobar: \(why)"
        case .notChecked(let why):
            return why
        }
    }

    // MARK: - Comprobación

    static func run(folder: URL, keysFile: URL) -> KeyCheck {
        guard let keys = try? loadKeys(keysFile) else { return KeyCheck(verdict: .unreadable("no puedo leer prod.keys")) }
        guard let hk = keys["header_key"], hk.count == 32 else { return KeyCheck(verdict: .noHeaderKey) }

        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let nsps = items.filter { ["nsp", "nsz"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        let skipped = items.filter { ["xci", "xcz"].contains($0.pathExtension.lowercased()) }.map(\.lastPathComponent)
        if nsps.isEmpty {
            return KeyCheck(verdict: .notChecked(skipped.isEmpty ? "No hay NSP/NSZ que comprobar" : "Los XCI no se pueden comprobar antes de construir"), skipped: [])
        }

        var missing = Set<String>(), missingFiles: [String] = []
        for file in nsps {
            let name = file.lastPathComponent
            do {
                let headers = try ncaHeaders(in: file)
                var fileMissing = false
                for raw in headers {
                    let h = decryptHeader(raw, key: hk)
                    guard h.count >= 0x400, let magic = String(bytes: h[0x200..<0x204], encoding: .ascii),
                          magic == "NCA3" || magic == "NCA2" else {
                        return KeyCheck(verdict: .headerKeyWrong(file: name), skipped: skipped)
                    }
                    for k in neededKeys(header: h) where !has(k, in: keys) {
                        missing.insert(k.name); fileMissing = true
                    }
                }
                if fileMissing { missingFiles.append(name) }
            } catch {
                return KeyCheck(verdict: .unreadable("\(name): \(error.localizedDescription)"), skipped: skipped)
            }
        }
        if !missing.isEmpty { return KeyCheck(verdict: .missing(keys: missing.sorted(), files: missingFiles), skipped: skipped) }
        return KeyCheck(verdict: .ok(files: nsps.count), skipped: skipped)
    }

    /// Una clave que hace falta: la derivada concreta, o master_key de la misma generación (LibHac deriva las demás de ella).
    struct Needed: Hashable { let name: String; let master: String }

    static func neededKeys(header h: [UInt8]) -> [Needed] {
        var gen = Int(max(h[0x206], h[0x220]))
        if gen > 0 { gen -= 1 }
        let g = String(format: "%02x", gen)
        let rightsID = h[0x230..<0x240].contains { $0 != 0 }
        if rightsID { return [Needed(name: "titlekek_\(g)", master: "master_key_\(g)")] }
        let area = ["application", "ocean", "system"][min(Int(h[0x207]), 2)]
        return [Needed(name: "key_area_key_\(area)_\(g)", master: "master_key_\(g)")]
    }

    private static func has(_ k: Needed, in keys: [String: [UInt8]]) -> Bool {
        keys[k.name] != nil || keys[k.master] != nil
    }

    /// prod.keys: líneas «nombre = hex». Solo se guardan en memoria, nunca se escriben.
    static func loadKeys(_ url: URL) throws -> [String: [UInt8]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: [UInt8]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let bytes = hexBytes(parts[1]) else { continue }
            out[parts[0].lowercased()] = bytes
        }
        return out
    }

    private static func hexBytes(_ s: String) -> [UInt8]? {
        let c = Array(s.utf8)
        guard c.count % 2 == 0, !c.isEmpty else { return nil }
        var out = [UInt8](); out.reserveCapacity(c.count / 2)
        var i = 0
        while i < c.count {
            guard let hi = hexVal(c[i]), let lo = hexVal(c[i + 1]) else { return nil }
            out.append(hi << 4 | lo); i += 2
        }
        return out
    }

    private static func hexVal(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 65...70: c - 55
        case 97...102: c - 87
        default: nil
        }
    }

    // MARK: - PFS0

    enum ReadError: LocalizedError {
        case notPFS0, truncated
        var errorDescription: String? { self == .notPFS0 ? "no es un NSP (PFS0)" : "archivo cortado" }
    }

    /// Los primeros 0x400 bytes de cada .nca / .ncz del PFS0.
    static func ncaHeaders(in url: URL) throws -> [[UInt8]] {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let head = try read(h, at: 0, count: 0x10)
        guard head.count == 0x10, Array(head[0..<4]) == Array("PFS0".utf8) else { throw ReadError.notPFS0 }
        let n = Int(le32(head, 4)), strSize = Int(le32(head, 8))
        guard n > 0, n < 10_000, strSize < 1 << 20 else { throw ReadError.notPFS0 }
        let table = try read(h, at: 0x10, count: n * 0x18 + strSize)
        guard table.count == n * 0x18 + strSize else { throw ReadError.truncated }
        let dataStart = UInt64(0x10 + n * 0x18 + strSize)
        let strings = table[(n * 0x18)...]
        var out: [[UInt8]] = []
        for i in 0..<n {
            let e = i * 0x18
            let off = le64(table, e), size = le64(table, e + 8), nameOff = Int(le32(table, e + 16))
            let start = strings.startIndex + nameOff
            guard start < strings.endIndex else { continue }
            let end = strings[start...].firstIndex(of: 0) ?? strings.endIndex
            let name = String(decoding: strings[start..<end], as: UTF8.self).lowercased()
            guard name.hasSuffix(".nca") || name.hasSuffix(".ncz"), size >= 0x400 else { continue }
            let hdr = try read(h, at: dataStart + off, count: 0x400)
            guard hdr.count == 0x400 else { throw ReadError.truncated }
            out.append(hdr)
        }
        return out
    }

    private static func read(_ h: FileHandle, at off: UInt64, count: Int) throws -> [UInt8] {
        try h.seek(toOffset: off)
        return [UInt8](try h.read(upToCount: count) ?? Data())
    }

    private static func le32(_ b: some Collection<UInt8>, _ o: Int) -> UInt32 {
        let a = Array(b); return UInt32(a[o]) | UInt32(a[o + 1]) << 8 | UInt32(a[o + 2]) << 16 | UInt32(a[o + 3]) << 24
    }

    private static func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) }
    }

    // MARK: - AES-128-XTS (variante de Nintendo)

    /// Descifra sectores de 0x200 empezando en el 0. key: 32 bytes (clave de datos + clave del tweak).
    static func decryptHeader(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        let k1 = Array(key[0..<16]), k2 = Array(key[16..<32])
        var out = [UInt8](repeating: 0, count: data.count)
        let sectors = data.count / 0x200
        for s in 0..<sectors {
            var tweak = [UInt8](repeating: 0, count: 16)
            var sn = UInt64(s)
            for i in (8..<16).reversed() { tweak[i] = UInt8(sn & 0xff); sn >>= 8 }   // big-endian
            tweak = ecb(tweak, key: k2, encrypt: true)
            for b in 0..<(0x200 / 16) {
                let o = s * 0x200 + b * 16
                var x = [UInt8](repeating: 0, count: 16)
                for i in 0..<16 { x[i] = data[o + i] ^ tweak[i] }
                let y = ecb(x, key: k1, encrypt: false)
                for i in 0..<16 { out[o + i] = y[i] ^ tweak[i] }
                // tweak *= α en GF(2^128), little-endian
                var carry: UInt8 = 0
                for i in 0..<16 {
                    let next = tweak[i] >> 7
                    tweak[i] = tweak[i] << 1 | carry
                    carry = next
                }
                if carry != 0 { tweak[0] ^= 0x87 }
            }
        }
        return out
    }

    private static func ecb(_ block: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        _ = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionECBMode),
                    key, 16, nil, block, 16, &out, 16, &moved)
        return out
    }
}

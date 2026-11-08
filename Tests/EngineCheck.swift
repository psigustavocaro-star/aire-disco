import Foundation
import Darwin

@main
struct EngineCheck {
    static func main() {
        do { try run() } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func run() throws {
        func expect(_ value: Bool, line: Int = #line) throws {
            if !value { throw SpaceError.invalid("Falló la verificación en la línea \(line)") }
        }
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/private/tmp/aire-check-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        let e = Engine(home: home, applicationDirectories: [applications])
        let old = Date(timeIntervalSinceNow: -9 * 86400)
        func make(_ relative: String, bytes: Data, age: Date = old) throws -> URL {
            let file = home.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            try fm.setAttributes([.modificationDate: age], ofItemAtPath: file.path)
            return file
        }
        let oldCache = try make(".npm/_cacache/content/old", bytes: Data(repeating: 8, count: 65_536))
        let fresh = try make(".npm/_cacache/content/fresh", bytes: Data([9]), age: Date())
        let claude = try make(".claude/session", bytes: Data([1, 2, 3]))
        let linkedRoot = home.appendingPathComponent("Library/Caches/pip/http")
        try fm.createDirectory(at: linkedRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: claude.deletingLastPathComponent())
        let outside = try make("Downloads/antiguo.dmg", bytes: Data(repeating: 4, count: 8_192))
        let scan = e.scanCaches([.packages], age: 86400, installers: true)
        try expect(scan.groups.flatMap(\.files).map(\.url) == [oldCache])
        try expect(scan.installers.count == 1 && scan.installers[0].url == outside)
        let clean = e.cleanCaches(scan.groups, title: "Prueba")
        print("Resultado de limpieza:",clean.done,clean.skipped,clean.errors)
        try expect(clean.done == 1 && clean.skipped == 0)
        try expect(!fm.fileExists(atPath: oldCache.path) && fm.fileExists(atPath: fresh.path))
        try expect(fm.fileExists(atPath: outside.path) && fm.fileExists(atPath: claude.path))
        print("Cachés: antigüedad, lista permitida, enlaces y separación de instaladores verificados")

        func makeApp(_ name: String, identifier: String, electron: Bool = true) throws {
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleName": name, "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"],
                format: .xml, options: 0
            )
            _ = try make("Applications/\(name).app/Contents/Info.plist", bytes: plist)
            if electron {
                try fm.createDirectory(at: applications.appendingPathComponent("\(name).app/Contents/Frameworks/Electron Framework.framework"),
                                       withIntermediateDirectories: true)
            }
        }
        try makeApp("Notas de prueba", identifier: "app.example.notes")
        try makeApp("App nativa", identifier: "app.example.native", electron: false)
        try makeApp("Asistente", identifier: "com.anthropic.example")
        var cacheMagic = UInt64(0xfcfb6d1ba7725c30).littleEndian
        let cacheData = withUnsafeBytes(of: &cacheMagic) { Data($0) } + Data(repeating: 5, count: 4096)
        let cachePath = "Library/Application Support/Notas de prueba/Cache/Cache_Data/"
        let indexFile = try make(cachePath + "index", bytes: cacheData)
        let cacheEntry = try make(cachePath + "entrada", bytes: cacheData)
        let ordinary = try make(cachePath + "documento", bytes: Data("archivo normal".utf8))
        let storage = try make("Library/Application Support/Notas de prueba/Local Storage/registro", bytes: cacheData)
        var excluded = [indexFile, ordinary, storage]
        for name in ["App nativa", "Asistente", "App sin instalar"] {
            _ = try make("Library/Application Support/\(name)/Cache/Cache_Data/index", bytes: cacheData)
            excluded.append(try make("Library/Application Support/\(name)/Cache/Cache_Data/entrada", bytes: cacheData))
        }
        let brave = try make("Library/Caches/BraveSoftware/Brave-Browser/Default/Cache/Cache_Data/archivo", bytes: cacheData)
        let universal = e.scanCaches([.apps, .browsers], age: 86400, installers: false)
        try expect(universal.groups.first { $0.kind == .apps }?.sources.map(\.name) == ["Notas de prueba"])
        try expect(universal.groups.first { $0.kind == .browsers }?.sources.map(\.name) == ["Brave"])
        try expect(Set(universal.groups.flatMap(\.files).map(\.url)) == [cacheEntry, brave])
        let universalResult = e.cleanCaches(universal.groups, title: "Prueba de detección")
        try expect(universalResult.done == 2 && universalResult.skipped == 0)
        try expect(excluded.allSatisfy { fm.fileExists(atPath: $0.path) })
        print("Detección: solo se incluyen cachés compatibles y se conserva el almacenamiento local")

        let originalData = Data((0..<2_100_000).map { UInt8(truncatingIfNeeded: $0 % 239) })
        let source = try make("Referencia/Original.pdf", bytes: originalData)
        let target = try make("Copias/Copia.pdf", bytes: originalData)
        let changed = try make("Copias/Cambio.pdf", bytes: originalData)
        let sameSizeDifferent = try make("Copias/Diferente.pdf", bytes: Data(repeating: 27, count: originalData.count))
        let link = home.appendingPathComponent("Copias/Enlace.pdf")
        try fm.linkItem(at: source, to: link)
        let linkedPairs = try e.scanDuplicates(reference: source.deletingLastPathComponent(), copies: target.deletingLastPathComponent(), minimumMiB: 2, previous: [:])
        try expect(linkedPairs.isEmpty)
        try fm.removeItem(at: link)

        let tags = Data("Etiqueta de prueba".utf8)
        let tagName = "app.airedisco.test-tag"
        try expect(tags.withUnsafeBytes { setxattr(target.path, tagName, $0.baseAddress, tags.count, 0, 0) } == 0)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        let pairs = try e.scanDuplicates(reference: source.deletingLastPathComponent(), copies: target.deletingLastPathComponent(), minimumMiB: 2, previous: [:])
        try expect(Set(pairs.map(\.target)) == Set([target, changed]) && !pairs.contains { $0.target == sameSizeDifferent })
        try Data("editado".utf8).write(to: changed)
        let originalInfo = e.info(target)!
        let (result, history) = e.optimizeDuplicates(pairs)
        print("Resultado de clonación:", result.done, result.skipped, result.errors)
        try expect(result.done == 1 && result.skipped == 1)
        try expect((try! Data(contentsOf: changed)) == Data("editado".utf8))
        try expect((try! Data(contentsOf: target)) == originalData)
        try expect(e.info(target)?.mode == originalInfo.mode && e.info(source)?.inode != e.info(target)?.inode)
        let pending = try e.scanDuplicates(reference: source.deletingLastPathComponent(), copies: target.deletingLastPathComponent(), minimumMiB: 2, previous: history)
        try expect(pending.isEmpty)
        let fd = try FileHandle(forWritingTo: target)
        try fd.write(contentsOf: Data([255, 255, 255]))
        try fd.close()
        try expect((try! Data(contentsOf: source)) == originalData)
        print("APFS: contenido, metadatos, edición independiente y cambios concurrentes verificados")
    }
}

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
        let e = Engine(home: home)
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

import Foundation
import CryptoKit
import Darwin

enum SpaceError: LocalizedError {
    case invalid(String)
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .system(let operation, let code): return "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

struct DiskSpace: Sendable {
    let free: Int64
    let capacity: Int64

    static func read(at path: URL) -> DiskSpace {
        var info = statfs()
        guard statfs(path.path, &info) == 0 else { return DiskSpace(free: 0, capacity: 0) }
        return DiskSpace(free: Int64(info.f_bavail) * Int64(info.f_bsize),
                         capacity: Int64(info.f_blocks) * Int64(info.f_bsize))
    }
}

enum CacheKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case browsers, apps, packages, updates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .browsers: return "Navegadores"
        case .apps: return "Aplicaciones"
        case .packages: return "Paquetes de desarrollo"
        case .updates: return "Actualizaciones"
        }
    }
    var icon: String {
        switch self {
        case .browsers: return "safari"
        case .apps: return "square.grid.2x2"
        case .packages: return "shippingbox"
        case .updates: return "arrow.down.circle"
        }
    }
    var details: String {
        switch self {
        case .browsers: return "Páginas y recursos temporales de navegación"
        case .apps: return "Recursos web temporales de aplicaciones compatibles"
        case .packages: return "Paquetes descargados por herramientas de desarrollo"
        case .updates: return "Paquetes de actualización y componentes en caché"
        }
    }
}

struct FileInfo: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let allocated: Int64
    let modified: timespec
    let changed: timespec
    let created: timespec
    let uid: uid_t
    let gid: gid_t
    let mode: mode_t
    let flags: UInt32
    let links: UInt16

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        allocated = value.st_blocks * 512
        modified = value.st_mtimespec
        changed = value.st_ctimespec
        created = value.st_birthtimespec
        uid = value.st_uid
        gid = value.st_gid
        mode = value.st_mode
        flags = value.st_flags
        links = value.st_nlink
    }

    static func == (a: FileInfo, b: FileInfo) -> Bool {
        a.device == b.device && a.inode == b.inode && a.size == b.size &&
        equalTime(a.modified, b.modified) && equalTime(a.changed, b.changed) &&
        a.mode == b.mode && a.flags == b.flags && a.links == b.links &&
        a.uid == b.uid && a.gid == b.gid
    }

    static func equalTime(_ a: timespec, _ b: timespec) -> Bool {
        a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec
    }

    var regular: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
    var local: Bool { flags & 0x40000000 == 0 }
    var time: TimeInterval { TimeInterval(modified.tv_sec) }
}

struct CacheFile: Sendable {
    let url: URL
    let info: FileInfo
}

struct CacheSource: Identifiable, Sendable {
    let name: String
    let bytes: Int64
    var id: String { name }
}

private struct CacheRoot {
    let url: URL
    let source: String
    var verifiesCacheFormat = false
}

struct CacheGroup: Identifiable, Sendable {
    let kind: CacheKind
    let files: [CacheFile]
    var sources: [CacheSource] = []
    var id: CacheKind { kind }
    var bytes: Int64 { files.reduce(0) { $0 + $1.info.allocated } }
}

enum InstallerKind: String, Sendable {
    case download = "Instalador descargado"
    case staging = "Instalación temporal de Codex"
}

struct Installer: Identifiable, Sendable {
    let url: URL
    let info: FileInfo
    let kind: InstallerKind
    let allocated: Int64
    var id: String { url.path }
}

struct Duplicate: Identifiable, Sendable {
    let source: URL
    let target: URL
    let sourceInfo: FileInfo
    let targetInfo: FileInfo
    let sha: String
    var id: String { target.path }
    var bytes: Int64 { targetInfo.size }
}

struct Result: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var title: String
    var done = 0
    var skipped = 0
    var before: Int64
    var after: Int64
    var errors: [String] = []
    var difference: Int64 { after - before }
}

struct CacheScan: Sendable {
    let groups: [CacheGroup]
    let installers: [Installer]
    let notes: [String]
}

struct Engine: Sendable {
    let home: URL
    private var fm: FileManager { FileManager.default }
    private let applicationDirectories: [URL]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, applicationDirectories: [URL]? = nil) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    var disk: DiskSpace { DiskSpace.read(at: home) }

    func info(_ url: URL) -> FileInfo? {
        var value = stat()
        return lstat(url.path, &value) == 0 ? FileInfo(value) : nil
    }

    private func cacheRoots(_ kind: CacheKind) -> [CacheRoot] {
        let base = home.appendingPathComponent("Library/Caches")
        let support = home.appendingPathComponent("Library/Application Support")
        func webCaches(_ profile: URL, source: String, includeGPU: Bool = false) -> [CacheRoot] {
            let paths = ["Cache/Cache_Data", "Code Cache/js", "Code Cache/wasm"]
                + (includeGPU ? ["GPUCache"] : [])
            return paths.map { CacheRoot(url: profile.appendingPathComponent($0), source: source) }
        }

        let roots: [CacheRoot]
        switch kind {
        case .browsers:
            let chromiumBrowsers = [
                ("Google/Chrome", "Chrome"),
                ("Chromium", "Chromium"),
                ("Microsoft Edge", "Edge"),
                ("BraveSoftware/Brave-Browser", "Brave"),
                ("Vivaldi", "Vivaldi")
            ]
            roots = chromiumBrowsers.flatMap { directory, name in
                children(base.appendingPathComponent(directory)).flatMap {
                    webCaches($0, source: name, includeGPU: true)
                }
            } + children(base.appendingPathComponent("Firefox/Profiles")).map {
                CacheRoot(url: $0.appendingPathComponent("cache2"), source: "Firefox")
            }
        case .apps:
            let codexCache = base.appendingPathComponent("Codex")
            let codexSupport = support.appendingPathComponent("Codex")
            let codexProfiles = [codexCache.appendingPathComponent("Default"), codexCache.appendingPathComponent("codex-browser-app"), codexSupport]
                + children(codexCache.appendingPathComponent("Default/Partitions"))
                + children(codexSupport.appendingPathComponent("Partitions"))
            let known = codexProfiles.flatMap { webCaches($0, source: "Codex") }
                + webCaches(support.appendingPathComponent("Notion/Partitions/notion"), source: "Notion")
                + webCaches(support.appendingPathComponent("discord"), source: "Discord")
                + [CacheRoot(url: base.appendingPathComponent("com.spotify.client/Browser/Cache"), source: "Spotify")]
            let detected = electronProfiles(cache: base, support: support).flatMap { profile, name in
                webCaches(profile, source: name).compactMap { root -> CacheRoot? in
                    let index = root.url.appendingPathComponent("index")
                    guard let entry = info(index), hasChromiumCacheHeader(index, entry: entry) else { return nil }
                    return CacheRoot(url: root.url, source: root.source, verifiesCacheFormat: true)
                }
            }
            roots = known + detected
        case .packages:
            roots = [CacheRoot(url: home.appendingPathComponent(".npm/_cacache"), source: "npm")]
                + ["http", "http-v2", "wheels"].map {
                    CacheRoot(url: base.appendingPathComponent("pip/\($0)"), source: "pip")
                }
        case .updates:
            roots = ["Google/GoogleUpdater/crx_cache", "Google/Chrome/component_crx_cache", "Google/Chrome/extensions_crx_cache"].map {
                CacheRoot(url: support.appendingPathComponent($0), source: "Google")
            }
        }

        var seen = Set<[Substring]>()
        return roots.filter { safePath($0.url) && seen.insert(components($0.url)).inserted }
    }

    private func electronProfiles(cache: URL, support: URL) -> [(URL, String)] {
        let directories = [cache, support].flatMap(children)
        let byName = Dictionary(grouping: directories, by: { $0.lastPathComponent.lowercased() })
        var profiles: [(URL, String)] = []
        for location in applicationDirectories {
            let applications = (try? fm.contentsOfDirectory(at: location, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])) ?? []
            for app in applications where app.pathExtension.lowercased() == "app" {
                guard fm.fileExists(atPath: app.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path),
                      let bundle = Bundle(url: app) else { continue }
                let fileName = app.deletingPathExtension().lastPathComponent
                let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                let identifier = bundle.bundleIdentifier ?? ""
                let names = [fileName, displayName, bundleName].compactMap { $0 }
                guard !([identifier] + names).contains(where: {
                    let name = $0.lowercased()
                    return name.contains("claude") || name.contains("anthropic")
                }) else { continue }
                let label = displayName ?? bundleName ?? fileName
                for name in Set(names.map { $0.lowercased() }) {
                    for directory in byName[name] ?? [] {
                        profiles.append((directory, label))
                        profiles.append(contentsOf: children(directory.appendingPathComponent("Partitions")).map { ($0, label) })
                        let standardProfile = directory.appendingPathComponent("Default")
                        profiles.append((standardProfile, label))
                        profiles.append(contentsOf: children(standardProfile.appendingPathComponent("Partitions")).map { ($0, label) })
                    }
                }
            }
        }
        return profiles
    }

    private func hasChromiumCacheHeader(_ url: URL, entry: FileInfo) -> Bool {
        guard entry.regular, entry.local, entry.size >= 8, safePath(url) else { return false }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var current = stat()
        guard fstat(descriptor, &current) == 0, FileInfo(current) == entry else { return false }
        // Chromium's Simple Cache file header, little-endian on both Mac architectures.
        var signature: UInt64 = 0
        let length = withUnsafeMutableBytes(of: &signature) { read(descriptor, $0.baseAddress, $0.count) }
        return length == 8 && UInt64(littleEndian: signature) == 0xfcfb6d1ba7725c30
    }

    func children(_ url: URL) -> [URL] {
        guard safePath(url) else { return [] }
        return (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    private func components(_ url: URL) -> [Substring] {
        url.standardizedFileURL.path.split(separator: "/")
    }

    private func descends(_ url: URL, from parent: URL) -> Bool {
        let path = components(url)
        let prefix = components(parent)
        return path.count > prefix.count && path.starts(with: prefix)
    }

    func safePath(_ url: URL) -> Bool {
        let path = components(url)
        guard descends(url, from: home), path == components(url.resolvingSymlinksInPath()) else { return false }
        let segments = path.dropFirst(components(home).count).map { $0.lowercased() }
        return !segments.contains { $0 == "claude" || $0 == ".claude" || $0.hasPrefix("claude-code") || $0.contains("anthropic") || $0 == "vm_bundles" }
    }

    func walk(_ root: URL, hidden: Bool = false, visit: (URL) -> Void) {
        guard safePath(root), let walker = fm.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isUbiquitousItemKey, .isPackageKey],
            options: hidden ? [] : [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let url as URL in walker {
            if Task.isCancelled { return }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isUbiquitousItemKey, .isPackageKey])
            if values?.isSymbolicLink == true || values?.isUbiquitousItem == true {
                walker.skipDescendants()
                continue
            }
            if values?.isDirectory == true {
                if !hidden && (Self.excludedFolders.contains(url.lastPathComponent.lowercased()) || !safePath(url)) {
                    walker.skipDescendants()
                }
                continue
            }
            visit(url)
        }
    }

    func scanCaches(_ kinds: Set<CacheKind>, age: TimeInterval, installers: Bool) -> CacheScan {
        let cutoff = Date().timeIntervalSince1970 - age
        let groups = CacheKind.allCases.filter(kinds.contains).map { kind in
            var files: [CacheFile] = []
            var sizes: [String: Int64] = [:]
            for root in cacheRoots(kind) {
                walk(root.url, hidden: true) { path in
                    if let file = info(path), file.regular, file.local, file.links == 1,
                        file.time < cutoff, file.allocated > 0 {
                        if root.verifiesCacheFormat {
                            guard path.lastPathComponent != "index",
                                  hasChromiumCacheHeader(path, entry: file) else { return }
                        }
                        files.append(CacheFile(url: path, info: file))
                        sizes[root.source, default: 0] += file.allocated
                    }
                }
            }
            let sources = sizes.map { CacheSource(name: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
            return CacheGroup(kind: kind, files: files, sources: sources)
        }
        var notes: [String] = []
        var found: [Installer] = []
        if installers {
            let downloads = home.appendingPathComponent("Downloads")
            do {
                for url in try fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.isUbiquitousItemKey]) {
                    if ["dmg", "pkg"].contains(url.pathExtension.lowercased()),
                       safePath(url), let entry = info(url), entry.regular, entry.local,
                       entry.links == 1, entry.time < Date().timeIntervalSince1970 - 7 * 86400,
                       (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) != true {
                        found.append(Installer(url: url, info: entry, kind: .download, allocated: entry.allocated))
                    }
                }
            } catch { notes.append("Descargas: \(error.localizedDescription)") }

            let runtime = home.appendingPathComponent(".cache/codex-runtimes")
            for folder in children(runtime) where validStaging(folder) {
                guard let entry = info(folder) else { continue }
                var size: Int64 = 0
                walk(folder, hidden: true) { path in
                    if let item = info(path), item.regular, item.local { size += item.allocated }
                }
                found.append(Installer(url: folder, info: entry, kind: .staging, allocated: size))
            }
        }
        return CacheScan(groups: groups, installers: found.sorted { $0.allocated > $1.allocated }, notes: notes)
    }

    func validStaging(_ url: URL) -> Bool {
        let runtime = home.appendingPathComponent(".cache/codex-runtimes")
        let active = runtime.appendingPathComponent("codex-primary-runtime")
        guard safePath(url), components(url.deletingLastPathComponent()) == components(runtime),
              url.lastPathComponent.range(of: #"^codex-runtime-install-[a-zA-Z0-9]{6}$"#, options: .regularExpression) != nil,
              let entry = info(url), entry.mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              entry.time < Date().timeIntervalSince1970 - 14 * 86400,
              let archive = info(url.appendingPathComponent("node-runtime.tar.xz")), archive.regular, archive.local,
              fm.isExecutableFile(atPath: active.appendingPathComponent("dependencies/node/bin/node").path),
              fm.isExecutableFile(atPath: active.appendingPathComponent("dependencies/python/bin/python3").path)
        else { return false }
        let names = Set(children(url).map(\.lastPathComponent))
        return names.contains("node-runtime.tar.xz") && names.isSubset(of: ["node-runtime.tar.xz", "payload"])
    }

    private func withDirectory<T>(_ dir: URL, _ body: (Int32) throws -> T) throws -> T {
        guard safePath(dir) else { throw SpaceError.invalid("Ruta fuera del alcance permitido") }
        let start = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard start >= 0 else { throw SpaceError.system("Abrir carpeta", errno) }
        var fd = start
        defer { close(fd) }
        for segment in components(dir).dropFirst(components(home).count) {
            let next = openat(fd, String(segment), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw SpaceError.system("Abrir carpeta", errno) }
            close(fd)
            fd = next
        }
        return try body(fd)
    }

    private func unchanged(_ file: FileInfo, name: String, parent: Int32) -> Bool {
        var status = stat()
        return fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 && FileInfo(status) == file
    }

    private func removeFile(_ candidate: CacheFile) throws {
        let url = candidate.url
        let name = url.lastPathComponent
        guard safePath(url), candidate.info.regular, candidate.info.local, candidate.info.links == 1 else {
            throw SpaceError.invalid("Archivo excluido")
        }
        try withDirectory(url.deletingLastPathComponent()) { dir in
            guard unchanged(candidate.info, name: name, parent: dir) else { throw SpaceError.invalid("El archivo cambió desde el análisis") }
            guard unlinkat(dir, name, 0) == 0 else { throw SpaceError.system("Eliminar", errno) }
        }
    }

    func cleanCaches(_ groups: [CacheGroup], title: String) -> Result {
        var result = Result(title: title, before: disk.free, after: 0)
        for group in groups {
            let allowed = cacheRoots(group.kind).map { components($0.url) }
            for file in group.files {
                guard !Task.isCancelled else { break }
                do {
                    let components = file.url.standardizedFileURL.path.split(separator: "/")
                    guard allowed.contains(where: { components.count > $0.count && components.starts(with: $0) })
                    else { throw SpaceError.invalid("Caché fuera de la lista permitida") }
                    try removeFile(file)
                    result.done += 1
                } catch { record(error, in: &result) }
            }
        }
        result.after = disk.free
        return result
    }

    func removeInstallers(_ installers: [Installer]) -> Result {
        var result = Result(title: "Instaladores revisados", before: disk.free, after: 0)
        for item in installers {
            do {
                guard info(item.url) == item.info, safePath(item.url) else { throw SpaceError.invalid("El instalador cambió desde el análisis") }
                switch item.kind {
                case .download:
                    guard components(item.url.deletingLastPathComponent()) == components(home.appendingPathComponent("Downloads")),
                          ["dmg", "pkg"].contains(item.url.pathExtension.lowercased()) else { throw SpaceError.invalid("Ruta de instalador excluida") }
                    guard try !installerInUse(item.url) else { throw SpaceError.invalid("El instalador está en uso") }
                    try removeFile(CacheFile(url: item.url, info: item.info))
                case .staging:
                    guard validStaging(item.url), try !installerInUse(item.url),
                          info(item.url) == item.info else { throw SpaceError.invalid("La instalación temporal ya no cumple las comprobaciones") }
                    try fm.removeItem(at: item.url)
                }
                result.done += 1
            } catch { record(error, in: &result) }
        }
        result.after = disk.free
        return result
    }

    private func installerInUse(_ url: URL) throws -> Bool {
        let command = Process()
        let output = Pipe()
        command.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        command.arguments = ["-nP", "-Fn", "-u", String(getuid())]
        command.standardOutput = output
        command.standardError = FileHandle.nullDevice
        try command.run()
        let watchdog = DispatchWorkItem { if command.isRunning { command.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        watchdog.cancel()
        guard command.terminationStatus == 0, let lines = String(data: data, encoding: .utf8), !lines.isEmpty else {
            throw SpaceError.invalid("No se pudo comprobar si el instalador está en uso")
        }
        if lines.split(separator: "\n").contains(where: { $0 == "n" + url.path || $0.hasPrefix("n" + url.path + "/") }) {
            return true
        }
        if url.pathExtension.lowercased() == "dmg" {
            let diskImages = Process()
            let imageOutput = Pipe()
            diskImages.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            diskImages.arguments = ["info", "-plist"]
            diskImages.standardOutput = imageOutput
            diskImages.standardError = FileHandle.nullDevice
            try diskImages.run()
            let imageWatchdog = DispatchWorkItem { if diskImages.isRunning { diskImages.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: imageWatchdog)
            let imageData = imageOutput.fileHandleForReading.readDataToEndOfFile()
            diskImages.waitUntilExit()
            imageWatchdog.cancel()
            guard diskImages.terminationStatus == 0,
                  let tree = try PropertyListSerialization.propertyList(from: imageData, format: nil) as? [String: Any],
                  let images = tree["images"] as? [[String: Any]]
            else { throw SpaceError.invalid("No se pudieron comprobar las imágenes montadas") }
            return images.contains { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path } == url.path }
        }
        return false
    }

    private func record(_ error: Error, in result: inout Result) {
        result.skipped += 1
        let message = error.localizedDescription
        if result.errors.count < 6 && !result.errors.contains(message) { result.errors.append(message) }
    }
}

extension Engine {
    static let excludedFolders: Set<String> = [
        "node_modules", "venv", "library", "cloudstorage", "mobile documents",
        "parallels", "virtual machines", "applications", "claude", "vm_bundles"
    ]
    static let documentTypes: Set<String> = ["pdf", "docx", "pptx", "xlsx", "jpg", "jpeg", "png", "heic", "tiff", "mov", "mp4", "m4a", "wav", "mp3", "zip"]

    func duplicateFolderOK(_ url: URL) -> Bool {
        guard safePath(url) else { return false }
        let relative = components(url).dropFirst(components(home).count)
        return !relative.contains {
            let name = $0.lowercased()
            return name.hasPrefix(".") || Self.excludedFolders.contains(name) ||
                   name.hasSuffix(".app") || name.hasSuffix(".imovielibrary") ||
                   name.hasSuffix(".photoslibrary") || name.hasSuffix(".bundle")
        } && (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) != true
    }

    func scanDuplicates(reference: URL, copies: URL, minimumMiB: Int, previous: [String: String]) throws -> [Duplicate] {
        guard duplicateFolderOK(reference), duplicateFolderOK(copies),
              components(reference) != components(copies), !descends(reference, from: copies),
              !descends(copies, from: reference)
        else { throw SpaceError.invalid("Selecciona dos carpetas locales distintas dentro de tu carpeta de usuario. Una no puede estar dentro de la otra.") }
        let cutoff = Date().timeIntervalSince1970 - 600
        let minSize = Int64(minimumMiB) * 1_048_576
        func eligible(_ url: URL) -> FileInfo? {
            guard Self.documentTypes.contains(url.pathExtension.lowercased()), let value = info(url),
                  value.regular, value.local, value.flags == 0, value.links == 1,
                  value.size >= minSize, value.allocated > 0, value.time < cutoff
            else { return nil }
            return value
        }
        var referenceSizes: [Int64: [CacheFile]] = [:]
        walk(reference) { url in
            if let entry = eligible(url) { referenceSizes[entry.size, default: []].append(CacheFile(url: url, info: entry)) }
        }
        var matches: [Duplicate] = []
        var quick: [URL: String] = [:]
        var full: [URL: String] = [:]
        walk(copies) { url in
            guard let entry = eligible(url), let sources = referenceSizes[entry.size] else { return }
            if previous[url.path] == identity(entry) { return }
            guard let probe = try? hash(url: url, sample: true) else { return }
            for source in sources where source.info.device == entry.device && source.info.inode != entry.inode {
                if quick[source.url] == nil { quick[source.url] = try? hash(url: source.url, sample: true) }
                guard quick[source.url] == probe else { continue }
                if full[source.url] == nil { full[source.url] = try? hash(url: source.url, sample: false) }
                guard let sha = full[source.url], (try? hash(url: url, sample: false)) == sha,
                      info(url) == entry, info(source.url) == source.info else { continue }
                matches.append(Duplicate(source: source.url, target: url, sourceInfo: source.info, targetInfo: entry, sha: sha))
                break
            }
        }
        return matches.sorted { $0.bytes > $1.bytes }
    }

    func identity(_ info: FileInfo) -> String {
        "\(info.device):\(info.inode):\(info.size):\(info.modified.tv_sec):\(info.modified.tv_nsec):\(info.changed.tv_sec):\(info.changed.tv_nsec)"
    }

    private func hash(url: URL, sample: Bool) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SpaceError.system("Leer archivo", errno) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw SpaceError.system("Inspeccionar archivo", errno) }
        let entry = FileInfo(status)
        guard entry.regular, entry.local else { throw SpaceError.invalid("Archivo no disponible localmente") }
        return try hash(handle: file, size: entry.size, sample: sample)
    }

    private func hash(handle: FileHandle, size: Int64, sample: Bool) throws -> String {
        try handle.seek(toOffset: 0)
        var sha = SHA256()
        if sample {
            sha.update(data: try handle.read(upToCount: 65_536) ?? Data())
            try handle.seek(toOffset: UInt64(max(0, size - 65_536)))
            sha.update(data: try handle.read(upToCount: 65_536) ?? Data())
        } else {
            while let block = try handle.read(upToCount: 4_194_304), !block.isEmpty {
                try Task.checkCancellation()
                sha.update(data: block)
            }
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func xattrs(_ fd: Int32) throws -> [String: Data] {
        let count = flistxattr(fd, nil, 0, 0)
        guard count >= 0 else { throw SpaceError.system("Leer atributos", errno) }
        var names = [UInt8](repeating: 0, count: count)
        guard count == 0 || flistxattr(fd, &names, count, 0) == count else { throw SpaceError.system("Leer atributos", errno) }
        var result: [String: Data] = [:]
        for bytes in names.split(separator: 0) {
            guard let key = String(bytes: bytes, encoding: .utf8) else { throw SpaceError.invalid("Atributo no representable") }
            if key == "com.apple.provenance" { continue }
            let length = fgetxattr(fd, key, nil, 0, 0, 0)
            guard length >= 0 else { throw SpaceError.system("Leer atributo", errno) }
            var value = Data(count: length)
            let got = value.withUnsafeMutableBytes { fgetxattr(fd, key, $0.baseAddress, length, 0, 0) }
            guard got == length else { throw SpaceError.system("Leer atributo", errno) }
            result[key] = value
        }
        return result
    }

    private func verifiedHandle(_ fd: Int32, expected: FileInfo) throws -> FileHandle {
        guard fd >= 0 else { throw SpaceError.system("Abrir copia", errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var status = stat()
        guard fstat(fd, &status) == 0, FileInfo(status) == expected else { throw SpaceError.invalid("El archivo cambió desde el análisis") }
        return handle
    }

    private func optimize(_ item: Duplicate) throws -> String {
        guard duplicateFolderOK(item.target.deletingLastPathComponent()),
              duplicateFolderOK(item.source.deletingLastPathComponent()), safePath(item.target), safePath(item.source),
              item.sourceInfo.regular, item.targetInfo.regular, item.sourceInfo.flags == 0, item.targetInfo.flags == 0,
              item.sourceInfo.links == 1, item.targetInfo.links == 1,
              item.sourceInfo.device == item.targetInfo.device else { throw SpaceError.invalid("Copia excluida") }

        let origin = try verifiedHandle(open(item.source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), expected: item.sourceInfo)
        defer { try? origin.close() }
        return try withDirectory(item.target.deletingLastPathComponent()) { dir in
            let name = item.target.lastPathComponent
            let target = try verifiedHandle(openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), expected: item.targetInfo)
            defer { try? target.close() }
            guard try hash(handle: target, size: item.bytes, sample: false) == item.sha else { throw SpaceError.invalid("La copia ya no es idéntica") }
            let temp = ".aire-disco-" + UUID().uuidString
            guard fclonefileat(origin.fileDescriptor, dir, temp, UInt32(CLONE_NOFOLLOW)) == 0
            else { throw SpaceError.system("Crear clon APFS", errno) }
            var removeTemp = true
            defer { if removeTemp { _ = unlinkat(dir, temp, 0) } }
            let fd = openat(dir, temp, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SpaceError.system("Abrir clon", errno) }
            let clone = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? clone.close() }

            let metadata = try xattrs(target.fileDescriptor)
            guard fcopyfile(target.fileDescriptor, fd, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw SpaceError.system("Copiar metadatos", errno)
            }
            let current = try xattrs(fd)
            for key in current.keys where metadata[key] == nil {
                guard fremovexattr(fd, key, 0) == 0 else { throw SpaceError.system("Retirar atributo heredado", errno) }
            }
            for (key, value) in metadata where current[key] != value {
                let result = value.withUnsafeBytes { fsetxattr(fd, key, $0.baseAddress, value.count, 0, 0) }
                guard result == 0 else { throw SpaceError.system("Conservar atributo", errno) }
            }

            var status = stat()
            guard fstat(fd, &status) == 0 else { throw SpaceError.system("Verificar clon", errno) }
            let newInfo = FileInfo(status)
            let oldInfo = item.targetInfo
            guard newInfo.mode == oldInfo.mode, newInfo.uid == oldInfo.uid, newInfo.gid == oldInfo.gid,
                  FileInfo.equalTime(newInfo.modified, oldInfo.modified), FileInfo.equalTime(newInfo.created, oldInfo.created),
                  try xattrs(fd) == metadata, try hash(handle: clone, size: item.bytes, sample: false) == item.sha
            else { throw SpaceError.invalid("La copia de prueba no conservó contenido y metadatos") }
            guard fsync(fd) == 0 else { throw SpaceError.system("Guardar clon", errno) }
            guard info(item.source) == item.sourceInfo, unchanged(item.targetInfo, name: name, parent: dir) else {
                throw SpaceError.invalid("El archivo cambió durante la comprobación")
            }
            guard renameatx_np(dir, temp, dir, name, UInt32(RENAME_SWAP)) == 0 else {
                throw SpaceError.system("Intercambiar copias", errno)
            }
            removeTemp = false
            var displaced = stat()
            var final = stat()
            let currentIsClone = fstatat(dir, name, &final, AT_SYMLINK_NOFOLLOW) == 0 && final.st_ino == newInfo.inode
            let readDisplaced = fstatat(dir, temp, &displaced, AT_SYMLINK_NOFOLLOW) == 0
            let displacedIsOriginal = readDisplaced && displaced.st_dev == oldInfo.device && displaced.st_ino == oldInfo.inode &&
                displaced.st_size == oldInfo.size && FileInfo.equalTime(displaced.st_mtimespec, oldInfo.modified)
            guard currentIsClone && displacedIsOriginal else {
                if currentIsClone && readDisplaced && renameatx_np(dir, temp, dir, name, UInt32(RENAME_SWAP)) == 0 {
                    removeTemp = true
                    throw SpaceError.invalid("Se revirtió un cambio concurrente")
                }
                throw SpaceError.invalid("Se conservó una copia de recuperación en \(item.target.deletingLastPathComponent().path)/\(temp)")
            }
            guard unlinkat(dir, temp, 0) == 0 else {
                throw SpaceError.invalid("Se conservó el archivo anterior en \(item.target.deletingLastPathComponent().path)/\(temp)")
            }
            return identity(FileInfo(final))
        }
    }

    func optimizeDuplicates(_ copies: [Duplicate]) -> (Result, [String: String]) {
        var result = Result(title: "Copias idénticas", before: disk.free, after: 0)
        var seen: [String: String] = [:]
        for item in copies {
            if Task.isCancelled { break }
            do {
                seen[item.id] = try optimize(item)
                result.done += 1
            } catch { record(error, in: &result) }
        }
        result.after = disk.free
        return (result, seen)
    }
}

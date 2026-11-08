import SwiftUI
import AppKit
import ServiceManagement

enum Page: String, CaseIterable, Identifiable {
    case overview = "Resumen"
    case cleanup = "Limpieza"
    case duplicates = "Copias idénticas"
    case automatic = "Automático"
    case activity = "Actividad"

    var id: Self { self }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .cleanup: return "sparkles"
        case .duplicates: return "square.on.square"
        case .automatic: return "clock.arrow.circlepath"
        case .activity: return "list.bullet.rectangle"
        }
    }
}

struct Preferences: Codable, Sendable {
    var kinds = Set(CacheKind.allCases)
    var automatic = false
    var interval = 6
    var threshold = 8
    var minimumDays = 2
    var manualHours = 1
    var minimumMiB = 10
}

@MainActor
final class Cleaner: ObservableObject {
    @Published var page: Page = .overview
    @Published var preferences: Preferences { didSet { store(preferences, "preferences") } }
    @Published var activity: [Result]
    @Published var space: DiskSpace
    @Published var cacheScan: CacheScan?
    @Published var pickedInstallers: Set<String> = []
    @Published var pickedCopies: Set<String> = []
    @Published var reference: URL?
    @Published var copies: URL?
    @Published var matches: [Duplicate] = []
    @Published var duplicateScanDone = false
    @Published var busy: String?
    @Published var notice: String?
    @Published var loginStatus = SMAppService.mainApp.status
    private let engine = Engine()
    private let defaults = UserDefaults.standard
    private var optimized: [String: String]
    private var timer: Timer?
    private var lastCheck: Date?

    init() {
        let defaults = UserDefaults.standard
        preferences = Self.load("preferences", from: defaults) ?? Preferences()
        activity = Self.load("activity", from: defaults) ?? []
        optimized = Self.load("optimized", from: defaults) ?? [:]
        lastCheck = defaults.object(forKey: "lastAutomaticCheck") as? Date
        space = Engine().disk
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { [weak self] in self?.tick() }
    }

    private static func load<T: Decodable>(_ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    func refresh() {
        space = engine.disk
        loginStatus = SMAppService.mainApp.status
    }

    var loginDescription: String {
        switch loginStatus {
        case .enabled: return "Activado"
        case .requiresApproval: return "Requiere aprobación en Ajustes del Sistema"
        case .notRegistered: return "Desactivado"
        case .notFound: return "Copia la app en Aplicaciones para configurarlo"
        @unknown default: return "Estado no disponible"
        }
    }

    func changeLogin() {
        do {
            if loginStatus == .enabled { try SMAppService.mainApp.unregister() }
            else if loginStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            else { try SMAppService.mainApp.register() }
        } catch { notice = error.localizedDescription }
        loginStatus = SMAppService.mainApp.status
    }

    private func record(_ result: Result) {
        activity.insert(result, at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
        store(activity, "activity")
        refresh()
    }

    func invalidateCaches() {
        cacheScan = nil
        pickedInstallers.removeAll()
    }

    func analyze() {
        guard busy == nil else { return }
        busy = "Analizando cachés e instaladores…"
        let engine = self.engine
        let p = preferences
        Task {
            let result = await Task.detached(priority: .utility) {
                engine.scanCaches(p.kinds, age: Double(p.manualHours) * 3600, installers: true)
            }.value
            cacheScan = result
            pickedInstallers.removeAll()
            busy = nil
            refresh()
        }
    }

    func clean() {
        guard busy == nil, let scan = cacheScan else { return }
        let groups = scan.groups.filter { preferences.kinds.contains($0.kind) && !$0.files.isEmpty }
        guard !groups.isEmpty else { return }
        busy = "Limpiando cachés seleccionadas…"
        let engine = self.engine
        Task {
            let result = await Task.detached(priority: .utility) { engine.cleanCaches(groups, title: "Limpieza manual") }.value
            record(result)
            invalidateCaches()
            notice = report(result, noun: "archivos de caché retirados")
            busy = nil
        }
    }

    func removeInstallers() {
        guard busy == nil else { return }
        let chosen = cacheScan?.installers.filter { pickedInstallers.contains($0.id) } ?? []
        guard !chosen.isEmpty else { return }
        busy = "Comprobando y retirando instaladores…"
        let engine = self.engine
        Task {
            let result = await Task.detached(priority: .utility) { engine.removeInstallers(chosen) }.value
            record(result)
            invalidateCaches()
            notice = report(result, noun: "instaladores retirados")
            busy = nil
        }
    }

    func chooseFolder(isReference: Bool) {
        let panel = NSOpenPanel()
        panel.title = isReference ? "Elegir carpeta de referencia" : "Elegir carpeta de copias"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = engine.home
        guard panel.runModal() == .OK, let folder = panel.url?.standardizedFileURL else { return }
        guard engine.duplicateFolderOK(folder) else {
            notice = "Elige una carpeta local de tu usuario. Las bibliotecas de apps, carpetas ocultas y ubicaciones en la nube están excluidas."
            return
        }
        if isReference { reference = folder } else { copies = folder }
        clearMatches()
    }

    func clearMatches() {
        matches = []
        pickedCopies.removeAll()
        duplicateScanDone = false
    }

    func findDuplicates() {
        guard busy == nil, let reference, let copies else { return }
        clearMatches()
        busy = "Comparando archivos…"
        let engine = self.engine
        let minimum = preferences.minimumMiB
        let known = optimized
        Task {
            do {
                matches = try await Task.detached(priority: .utility) {
                    try engine.scanDuplicates(reference: reference, copies: copies, minimumMiB: minimum, previous: known)
                }.value
                duplicateScanDone = true
            } catch { notice = error.localizedDescription }
            busy = nil
        }
    }

    func optimizeCopies() {
        guard busy == nil else { return }
        let chosen = matches.filter { pickedCopies.contains($0.id) }
        guard !chosen.isEmpty else { return }
        busy = "Verificando y optimizando copias APFS…"
        let engine = self.engine
        Task {
            let (result, identities) = await Task.detached(priority: .utility) { engine.optimizeDuplicates(chosen) }.value
            if optimized.count > 10_000 { optimized.removeAll() }
            optimized.merge(identities) { _, newest in newest }
            store(optimized, "optimized")
            matches.removeAll { identities[$0.id] != nil }
            pickedCopies.removeAll()
            record(result)
            notice = report(result, noun: "copias optimizadas")
            busy = nil
        }
    }

    func tick() {
        refresh()
        guard preferences.automatic, busy == nil, !preferences.kinds.isEmpty, space.capacity > 0,
              space.free < Int64(preferences.threshold) * 1_000_000_000,
              lastCheck.map({ Date().timeIntervalSince($0) >= Double(preferences.interval) * 3600 }) ?? true
        else { return }
        lastCheck = Date()
        defaults.set(lastCheck, forKey: "lastAutomaticCheck")
        busy = "Ejecutando limpieza automática…"
        let engine = self.engine
        let p = preferences
        Task {
            let result = await Task.detached(priority: .utility) {
                let scan = engine.scanCaches(p.kinds, age: Double(p.minimumDays) * 86400, installers: false)
                return engine.cleanCaches(scan.groups, title: "Limpieza automática")
            }.value
            record(result)
            invalidateCaches()
            busy = nil
        }
    }

    private func report(_ result: Result, noun: String) -> String {
        let summary = "\(result.done) \(noun). \(result.skipped > 0 ? "\(result.skipped) omitidos. " : "")Espacio libre ahora: \(quantity(result.after))."
        return result.errors.isEmpty ? summary : summary + "\n" + result.errors.joined(separator: "\n")
    }
}

let windowBackground = Color(nsColor: .windowBackgroundColor)
let panelBackground = Color(nsColor: .controlBackgroundColor)
let separator = Color(nsColor: .separatorColor)
let secondaryInk = Color(nsColor: .secondaryLabelColor)
let accent = Color(nsColor: NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
        return NSColor(srgbRed: 0.42, green: 0.83, blue: 0.73, alpha: 1)
    }
    return NSColor(srgbRed: 0.04, green: 0.46, blue: 0.41, alpha: 1)
})

func quantity(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .decimal
    f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    return f.string(fromByteCount: max(0, bytes))
}

func deltaText(_ value: Int64) -> String {
    if value > 0 { return "+\(quantity(value))" }
    if value < 0 { return "−\(quantity(-value))" }
    return "0 KB"
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(panelBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(separator.opacity(0.42)))
    }
}

struct Logo: View {
    let size: CGFloat
    var body: some View {
        if let url = Bundle.main.url(forResource: "Logo", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "internaldrive.fill").font(.system(size: size * 0.5)).foregroundStyle(accent)
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

struct MainWindow: View {
    @ObservedObject var model: Cleaner
    @State private var confirm: Confirm?
    @Environment(\.scenePhase) private var phase

    enum Confirm: String, Identifiable {
        case caches, installers, duplicates
        var id: Self { self }
        var title: String {
            switch self {
            case .caches: return "Limpiar las cachés seleccionadas"
            case .installers: return "Eliminar instaladores seleccionados"
            case .duplicates: return "Optimizar las copias seleccionadas"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                if let status = model.busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 27).padding(.vertical, 10)
                    .background(accent.opacity(0.10))
                    .accessibilityElement(children: .combine)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        switch model.page {
                        case .overview: overview
                        case .cleanup: cleanup
                        case .duplicates: duplicates
                        case .automatic: automatic
                        case .activity: history
                        }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(windowBackground)
        .tint(accent)
        .frame(minWidth: 850, minHeight: 560)
        .onChange(of: phase) { _, value in if value == .active { model.refresh() } }
        .alert(item: $confirm) { item in
            switch item {
            case .caches:
                Alert(title: Text(item.title), message: Text("Se eliminarán los archivos de caché detectados. Las aplicaciones podrán regenerarlos."),
                      primaryButton: .destructive(Text("Limpiar"), action: model.clean), secondaryButton: .cancel(Text("Cancelar")))
            case .installers:
                Alert(title: Text(item.title), message: Text("Se eliminarán definitivamente \(model.pickedInstallers.count) elementos. Verifica los nombres en la lista antes de continuar."),
                      primaryButton: .destructive(Text("Eliminar ahora"), action: model.removeInstallers), secondaryButton: .cancel(Text("Cancelar")))
            case .duplicates:
                Alert(title: Text(item.title), message: Text("Se verificará de nuevo el contenido de \(model.pickedCopies.count) copias. Cada archivo conservará su ruta y se podrá seguir editando por separado."),
                      primaryButton: .default(Text("Optimizar"), action: model.optimizeCopies), secondaryButton: .cancel(Text("Cancelar")))
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Logo(size: 35)
                Text("Aire Disco").font(.system(size: 16, weight: .semibold))
            }.padding(.bottom, 17)
            ForEach(Page.allCases) { page in
                Button {
                    model.page = page
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: page.icon).frame(width: 18)
                        Text(page.rawValue)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: model.page == page ? .semibold : .medium))
                    .padding(.horizontal, 11).padding(.vertical, 10)
                    .background(model.page == page ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(model.page == page ? accent : secondaryInk)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityAddTraits(model.page == page ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 23)
        .frame(width: 187)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func heading(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(description).font(.system(size: 13)).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 2)
    }

    private var overview: some View {
        Group {
            heading("Almacenamiento", "Espacio disponible en el volumen de tu usuario.")
            spaceCard
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    shortcut("sparkle.magnifyingglass", "Revisar cachés e instaladores", .cleanup)
                    Divider()
                    shortcut("square.on.square", "Comparar carpetas", .duplicates)
                }
            }
            Card {
                HStack(alignment: .center, spacing: 11) {
                    Image(systemName: "clock").font(.system(size: 17)).foregroundStyle(secondaryInk).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Limpieza automática").font(.system(size: 13, weight: .semibold))
                        Text(model.preferences.automatic
                            ? "Activada · Umbral de \(model.preferences.threshold) GB · Intervalo mínimo de \(model.preferences.interval) h"
                            : "Desactivada").font(.system(size: 12)).foregroundStyle(secondaryInk)
                    }
                    Spacer()
                    Button("Configurar") { model.page = .automatic }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var spaceCard: some View {
        let ratio = model.space.capacity > 0 ? max(0, min(1, Double(model.space.free) / Double(model.space.capacity))) : 0
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.space.capacity == 0 ? "Lectura no disponible" : quantity(model.space.free))
                            .font(.system(size: 39, weight: .semibold)).monospacedDigit()
                        Text("Disponibles de \(quantity(model.space.capacity))").font(.system(size: 12)).foregroundStyle(secondaryInk)
                    }
                    Spacer()
                    Button { model.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }.buttonStyle(.bordered).help("Actualizar espacio disponible").accessibilityLabel("Actualizar espacio disponible")
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(separator.opacity(0.45))
                        Capsule().fill(accent).frame(width: model.space.free > 0 ? max(4, ratio * proxy.size.width) : 0)
                    }
                }.frame(height: 5).accessibilityHidden(true)
            }
        }
    }

    private func shortcut(_ icon: String, _ title: String, _ page: Page) -> some View {
        Button {
            model.page = page
        } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(accent).frame(width: 24)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(secondaryInk)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var cleanup: some View {
        Group {
            heading("Limpieza", "Analiza las categorías seleccionadas y revisa los resultados.")
            Card {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(CacheKind.allCases) { kind in
                        HStack(spacing: 10) {
                            Image(systemName: kind.icon).foregroundStyle(accent).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(kind.title).font(.system(size: 13, weight: .semibold))
                                Text(kind.details).font(.system(size: 11)).foregroundStyle(secondaryInk)
                            }
                            Spacer()
                            if let group = model.cacheScan?.groups.first(where: { $0.kind == kind }) {
                                Text(quantity(group.bytes)).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(secondaryInk)
                            }
                            Toggle(kind.title, isOn: Binding(get: { model.preferences.kinds.contains(kind) }, set: {
                                if $0 { model.preferences.kinds.insert(kind) } else { model.preferences.kinds.remove(kind) }
                                model.invalidateCaches()
                            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                    }
                    Divider()
                    HStack {
                        Picker("Antigüedad mínima", selection: $model.preferences.manualHours) {
                            Text("1 hora").tag(1)
                            Text("1 día").tag(24)
                            Text("3 días").tag(72)
                            Text("7 días").tag(168)
                        }.fixedSize().onChange(of: model.preferences.manualHours) { _, _ in model.invalidateCaches() }
                        Spacer()
                        Button("Analizar") { model.analyze() }.buttonStyle(.bordered)
                        Button("Limpiar cachés") { confirm = .caches }.buttonStyle(.borderedProminent)
                            .disabled(!(model.cacheScan?.groups.contains { !$0.files.isEmpty } ?? false))
                    }
                    if let scan = model.cacheScan {
                        let logical = scan.groups.reduce(0) { $0 + $1.bytes }
                        Text("\(quantity(logical)) de caché detectada. El espacio recuperado se mide en el volumen.")
                            .font(.system(size: 11)).foregroundStyle(secondaryInk)
                    }
                }
            }.disabled(model.busy != nil)
            if let scan = model.cacheScan {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Instaladores").font(.headline)
                        if scan.installers.isEmpty {
                            Text("Sin instaladores pendientes de revisión.").foregroundStyle(secondaryInk).font(.system(size: 12))
                        }
                        ForEach(scan.installers) { item in
                            HStack {
                                Toggle(isOn: membership(item.id, $model.pickedInstallers)) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                        Text(item.kind.rawValue).font(.caption).foregroundStyle(secondaryInk)
                                    }
                                }.toggleStyle(.checkbox)
                                Spacer()
                                Text(quantity(item.allocated)).font(.caption).foregroundStyle(secondaryInk)
                                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                                    Image(systemName: "folder")
                                }.buttonStyle(.borderless).help("Mostrar en Finder").accessibilityLabel("Mostrar en Finder")
                            }
                        }
                        ForEach(scan.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        if !scan.installers.isEmpty {
                            Button("Eliminar seleccionados…") { confirm = .installers }.buttonStyle(.bordered)
                                .disabled(model.pickedInstallers.isEmpty)
                        }
                    }
                }.disabled(model.busy != nil)
            }
        }
    }

    private var duplicates: some View {
        Group {
            heading("Copias idénticas", "Compara dos carpetas del mismo volumen y conserva ambas rutas.")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    folderLine("Referencia", "Se usa para comparar el contenido.", model.reference, true)
                    Divider()
                    folderLine("Copias", "Aquí se optimizan los archivos que selecciones.", model.copies, false)
                    Divider()
                    HStack {
                        Picker("Tamaño mínimo", selection: $model.preferences.minimumMiB) {
                            Text("2 MB").tag(2)
                            Text("10 MB").tag(10)
                            Text("20 MB").tag(20)
                            Text("50 MB").tag(50)
                        }.fixedSize().onChange(of: model.preferences.minimumMiB) { _, _ in model.clearMatches() }
                        Spacer()
                        Button("Comparar carpetas") { model.findDuplicates() }.buttonStyle(.borderedProminent)
                            .disabled(model.reference == nil || model.copies == nil)
                    }
                }
            }.disabled(model.busy != nil)
            if model.duplicateScanDone {
                Card {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Text("\(model.matches.count) coincidencias nuevas").font(.headline)
                            Spacer()
                            if !model.matches.isEmpty {
                                Button(model.pickedCopies.count == model.matches.count ? "Quitar selección" : "Seleccionar todas") {
                                    if model.pickedCopies.count == model.matches.count { model.pickedCopies.removeAll() }
                                    else { model.pickedCopies = Set(model.matches.map(\.id)) }
                                }.buttonStyle(.bordered)
                            }
                        }
                        if model.matches.isEmpty { Text("Sin copias pendientes de optimización.").font(.caption).foregroundStyle(secondaryInk) }
                        if !model.matches.isEmpty {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 9) {
                                    ForEach(model.matches) { pair in
                                        HStack {
                                            Toggle(isOn: membership(pair.id, $model.pickedCopies)) {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(pair.target.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                                    Text(pair.target.deletingLastPathComponent().path).font(.caption2).foregroundStyle(secondaryInk).lineLimit(1).truncationMode(.head)
                                                }
                                            }.toggleStyle(.checkbox)
                                            .help("Referencia: \(pair.source.path)")
                                            Spacer()
                                            Text(quantity(pair.bytes)).font(.caption).foregroundStyle(secondaryInk)
                                            Button { NSWorkspace.shared.activateFileViewerSelecting([pair.target]) } label: {
                                                Image(systemName: "folder")
                                            }.buttonStyle(.borderless).help("Mostrar copia en Finder").accessibilityLabel("Mostrar copia en Finder")
                                        }
                                    }
                                }.padding(.vertical, 3)
                            }.frame(height: min(260, CGFloat(model.matches.count) * 40 + 6))
                            HStack {
                                Text("Tamaño lógico seleccionado: \(quantity(model.matches.filter { model.pickedCopies.contains($0.id) }.reduce(0) { $0 + $1.bytes }))")
                                    .font(.caption).foregroundStyle(secondaryInk)
                                Spacer()
                                Button("Optimizar selección…") { confirm = .duplicates }.buttonStyle(.borderedProminent)
                                    .disabled(model.pickedCopies.isEmpty)
                            }
                        }
                    }
                }.disabled(model.busy != nil)
            }
        }
    }

    private func folderLine(_ label: String, _ detail: String, _ folder: URL?, _ isReference: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: isReference ? "folder" : "folder.badge.gearshape").foregroundStyle(accent).frame(width: 23)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 13, weight: .semibold))
                Text(folder?.path ?? detail).font(.caption).foregroundStyle(secondaryInk).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Button("Elegir…") { model.chooseFolder(isReference: isReference) }.buttonStyle(.bordered)
                .accessibilityLabel("Elegir carpeta de \(label.lowercased())")
        }
    }

    private var automatic: some View {
        Group {
            heading("Limpieza automática", "Configura cuándo se limpian las cachés mientras la app está abierta.")
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Limpiar cachés automáticamente", isOn: $model.preferences.automatic)
                        .toggleStyle(.switch).font(.headline)
                    Divider()
                    HStack {
                        Picker("Limpiar por debajo de", selection: $model.preferences.threshold) {
                            ForEach([3, 5, 8, 12, 20], id: \.self) { Text("\($0) GB").tag($0) }
                        }.fixedSize()
                        Spacer()
                        Picker("Intervalo mínimo", selection: $model.preferences.interval) {
                            ForEach([1, 3, 6, 12, 24], id: \.self) { Text("\($0) h").tag($0) }
                        }.fixedSize()
                    }
                    Picker("Antigüedad mínima de la caché", selection: $model.preferences.minimumDays) {
                        ForEach([1, 2, 3, 7], id: \.self) { Text($0 == 1 ? "1 día" : "\($0) días").tag($0) }
                    }.fixedSize()
                    Text("Categorías activas: \(CacheKind.allCases.filter(model.preferences.kinds.contains).map(\.title).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(secondaryInk)
                    Button("Editar categorías") { model.page = .cleanup }.buttonStyle(.bordered)
                }
            }.disabled(model.busy != nil)
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "power").font(.system(size: 21)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Abrir al iniciar sesión").font(.headline)
                        Text(model.loginDescription).font(.caption).foregroundStyle(secondaryInk)
                    }
                    Spacer()
                    Button(model.loginStatus == .enabled ? "Desactivar" : model.loginStatus == .requiresApproval ? "Abrir Ajustes" : "Activar") {
                        model.changeLogin()
                    }.buttonStyle(.bordered)
                }
            }
            Text("Al cerrar la ventana, la app permanece en la barra de menús.")
                .font(.system(size: 12)).foregroundStyle(secondaryInk)
        }
    }

    private var history: some View {
        Group {
            heading("Actividad", "Espacio disponible antes y después de cada operación.")
            if model.activity.isEmpty {
                Card { Text("Aún no hay limpiezas registradas.").foregroundStyle(secondaryInk) }
            }
            ForEach(model.activity) { event in
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.title).font(.headline)
                            Spacer()
                            Text(deltaText(event.difference)).font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(event.difference > 0 ? accent : secondaryInk)
                        }
                        Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(secondaryInk)
                        Text("Espacio libre: \(quantity(event.before)) → \(quantity(event.after))  ·  \(event.done) procesados  ·  \(event.skipped) omitidos")
                            .font(.system(size: 12)).foregroundStyle(secondaryInk)
                        ForEach(event.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
        }
    }

    private func membership(_ id: String, _ set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) }, set: { flag in
            if flag { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
        })
    }
}

struct AireRoot: View {
    @ObservedObject var model: Cleaner
    var body: some View {
        MainWindow(model: model)
            .alert("Aire Disco", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("Aceptar") { model.notice = nil }
            } message: { Text(model.notice ?? "") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AireDiscoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Cleaner()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Aire Disco", id: "aire-window") { AireRoot(model: model) }
            .defaultSize(width: 940, height: 630)
        MenuBarExtra {
            Text("\(quantity(model.space.free)) libres")
            if let busy = model.busy { Text(busy) }
            Divider()
            Button("Abrir Aire Disco") {
                openWindow(id: "aire-window")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Revisar limpieza") {
                model.page = .cleanup
                openWindow(id: "aire-window")
                NSApp.activate(ignoringOtherApps: true)
            }
            Toggle("Limpieza automática", isOn: $model.preferences.automatic)
                .disabled(model.busy != nil)
            Divider()
            Button("Salir de Aire Disco") { NSApp.terminate(nil) }
        } label: {
            Label("Aire Disco", systemImage: "internaldrive")
        }
    }
}

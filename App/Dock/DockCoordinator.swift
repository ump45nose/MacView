import AppKit
import MVFoundation
import MVLayout
import MVSettings
import os

/// 全应用的停靠协调者：保存 layout.json、管理共享的浮动面板、在窗口之间移动面板。
///
/// - 每个窗口有自己的停靠区（`WindowDock.dockLayout`）；浮动面板全应用共享，作用于当前活动窗口。
/// - `current` 是最近一次改动后的完整布局：新窗口套用它的停靠区，它也是去抖后写进 layout.json 的内容。
/// - 变换都经 `perform` 或 `commit`：先算出新布局，再让涉及的窗口和浮动面板跟上。
///   面板离开一处时实例先放进 `pool`，同一轮里移到别处时取回，视图和状态保留。
@MainActor
final class DockCoordinator {
    struct Problem: Equatable {
        var title: String
        var detail: String
    }

    static let layoutFileKey = "MVLayoutFile"
    static let schemesFileName = "layout-schemes.json"
    static let saveDelay: Duration = .milliseconds(500)

    let fileURL: URL
    let schemesFileURL: URL
    private let store: JSONDocumentStore<DockLayout>?
    private let schemesStore: JSONDocumentStore<LayoutSchemesFile>?
    private(set) var current: DockLayout
    private(set) var docks: [WindowDock] = []
    private(set) weak var active: WindowDock?
    private(set) var floatingWindows: [PanelID: FloatingPanelWindow] = [:]
    private(set) var drag: (panel: PanelID, source: WindowDock?)?
    private(set) var problem: Problem? {
        didSet { docks.forEach { $0.showProblem(problem) } }
    }
    /// `layout-schemes.json` 解析失败的说明；修好后为 nil。
    private(set) var schemesProblem: String?
    /// 方案文件或方案列表变化后调用（供设置页刷新）。
    var onSchemesChange: (() -> Void)?
    private var pool: [PanelID: any DockPanel] = [:]
    /// 每个窗口的保存布局（含当前不可用的插件面板位置与选中项，floating 为空）。
    private var savedLayouts: [ObjectIdentifier: DockLayout] = [:]
    private var keepOnTop = false
    private var saveTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private var observeSchemesTask: Task<Void, Never>?
    private var panelsObserver: NSObjectProtocol?
    private let logger = Logger(category: "dock")

    private var availablePanels: Set<PanelID> {
        Set(DockPanels.all.map(\.id))
    }

    /// `~/Library/Application Support/MacView/layout.json`；自检用 `-MVLayoutFile <路径>` 换成临时文件。
    static func defaultFileURL() -> URL {
        if let path = UserDefaults.standard.string(forKey: layoutFileKey) { return URL(fileURLWithPath: path) }
        return URL.applicationSupportDirectory.appending(path: "MacView/layout.json")
    }

    static func defaultSchemesFileURL(supportDirectory: URL) -> URL {
        supportDirectory.appending(path: schemesFileName)
    }

    init(fileURL: URL, schemesFileURL: URL? = nil) {
        self.fileURL = fileURL
        let schemesURL = schemesFileURL ?? fileURL.deletingLastPathComponent().appending(path: Self.schemesFileName)
        self.schemesFileURL = schemesURL
        let known = Set(DockPanels.all.map(\.id))
        do {
            let store = try JSONDocumentStore(fileURL: fileURL, version: 1, defaultValue: DockPanels.defaultLayout)
            self.store = store
            // 解析失败时 store 给出默认值，错误经 changes 报告。
            current = store.value().sanitized(knownPanels: known)
        } catch {
            store = nil
            current = DockPanels.defaultLayout
            problem = Problem(
                title: String(localized: "无法打开 layout.json"),
                detail: ErrorText.describe(error) + "\n" + String(localized: "停靠布局不会保存。")
            )
        }
        do {
            schemesStore = try JSONDocumentStore(fileURL: schemesURL, version: 1, defaultValue: LayoutSchemesFile())
        } catch {
            schemesStore = nil
            schemesProblem = ErrorText.describe(error)
            logger.error("无法打开 layout-schemes.json：\(String(describing: error), privacy: .public)")
        }
        observeTask = Task { [weak self, store = self.store] in
            guard let store else { return }
            for await change in store.changes() {
                self?.documentChanged(change)
            }
        }
        observeSchemesTask = Task { [weak self, schemesStore = self.schemesStore] in
            guard let schemesStore else { return }
            for await change in schemesStore.changes() {
                guard let self, !Task.isCancelled else { return }
                switch change {
                case let .fileError(message):
                    self.logger.error("layout-schemes.json：\(message, privacy: .public)")
                    self.schemesProblem = message
                    self.onSchemesChange?()
                case .reloaded:
                    self.schemesProblem = nil
                    self.onSchemesChange?()
                }
            }
        }
        panelsObserver = NotificationCenter.default.addObserver(
            forName: DockPanels.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePanelsChanged()
            }
        }
    }

    isolated deinit {
        saveTask?.cancel()
        observeTask?.cancel()
        observeSchemesTask?.cancel()
        if let panelsObserver {
            NotificationCenter.default.removeObserver(panelsObserver)
        }
    }

    private func documentChanged(_ change: DocumentChange) {
        switch change {
        case let .fileError(message):
            logger.error("layout.json：\(message, privacy: .public)")
            problem = Problem(
                title: String(localized: "layout.json 无法解析，已改用默认布局"),
                detail: message + "\n" + String(localized: "调整布局后会覆盖这个文件。")
            )
        case .reloaded:
            // 文件已可用（本程序写入或外部修好）。外部修改不套用到已打开的窗口，新窗口会读到它。
            problem = nil
        }
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: 窗口

    /// 窗口就绪：套用默认布局（`current` 的停靠区）。
    func attach(_ dock: WindowDock, to owner: ReaderWindowController) {
        dock.owner = owner
        docks.append(dock)
        dock.showProblem(problem)
        commit([(dock, current)], current: current, save: false)
        if active == nil { activate(dock) }
    }

    /// 恢复会话：这个窗口用保存的布局，浮动面板不动。
    func restore(_ dock: WindowDock, layout: DockLayout) {
        let known = availablePanels
        commit([(dock, layout.sanitized(knownPanels: known).adoptingFloating(of: current))], current: current, save: false)
    }

    func detach(_ dock: WindowDock) {
        docks.removeAll { $0 === dock }
        savedLayouts.removeValue(forKey: ObjectIdentifier(dock))
        dock.detach()
        pool.removeAll()
        if active === dock || active == nil {
            active = nil
            if let next = docks.last {
                activate(next)
            } else {
                for window in floatingWindows.values { window.panel.bind(to: nil) }
                syncFloating()
            }
        }
    }

    /// 活动窗口改变：浮动面板改为作用于它。
    func activate(_ dock: WindowDock) {
        active = dock
        for window in floatingWindows.values { window.panel.bind(to: dock.owner) }
        syncFloating()
    }

    /// 面板注册表增删（如插件启用或停用）时，按保存布局重新投影各窗口与浮动面板。
    private func handlePanelsChanged() {
        let available = availablePanels
        for (id, window) in Array(floatingWindows) {
            if !available.contains(id) {
                floatingWindows[id] = nil
                window.panel.bind(to: nil)
                window.dismiss()
            } else if let type = DockPanels.type(id) {
                window.update(type: type)
            }
        }
        for dock in docks {
            let saved = savedLayouts[ObjectIdentifier(dock)] ?? Self.docked(current)
            dock.apply(Self.docked(saved.displayed(available: available)), render: true)
        }
        syncFloating()
        pool.removeAll()
    }

    // MARK: 变换

    /// 在一个窗口（nil 时只涉及浮动面板）上变换布局。
    /// 变换在显示布局上执行，再把当前不可用的插件面板并回保存布局。
    func perform(in dock: WindowDock?, render: Bool = true, _ transform: (DockLayout) -> DockLayout) {
        let available = availablePanels
        let savedBase = savedLayout(of: dock)
        let displayedBase = savedBase.displayed(available: available)
        let displayedNext = transform(displayedBase)
        guard displayedNext != displayedBase else { return }
        let savedNext = displayedNext.merging(unavailableFrom: savedBase, available: available)
        commit(dock.map { [($0, savedNext)] } ?? [], current: savedNext, render: render)
    }

    /// 让各窗口与浮动面板跟上新保存布局，并去抖保存。`updates` 中的窗口按顺序套用（跨窗口移动时先源后目标）。
    private func commit(_ updates: [(WindowDock, DockLayout)], current next: DockLayout, render: Bool = true, save: Bool = true) {
        let available = availablePanels
        let floatingChanged = next.floating.map(\.panel) != current.floating.map(\.panel)
        current = next
        let displayedFloating = Set(next.displayed(available: available).floating.map(\.panel))
        for (id, window) in Array(floatingWindows) where !displayedFloating.contains(id) {
            floatingWindows[id] = nil
            if available.contains(id) {
                pool[id] = window.panel
            } else {
                window.panel.bind(to: nil)
            }
            window.dismiss()
        }
        for (dock, saved) in updates {
            let dockedSaved = Self.docked(saved)
            savedLayouts[ObjectIdentifier(dock)] = dockedSaved
            dock.apply(Self.docked(dockedSaved.displayed(available: available)), render: render)
        }
        if floatingChanged {
            for dock in docks where !updates.contains(where: { $0.0 === dock }) {
                let baseSaved = savedLayouts[ObjectIdentifier(dock)] ?? Self.docked(current)
                let adoptedSaved = Self.docked(baseSaved.adoptingFloating(of: next))
                savedLayouts[ObjectIdentifier(dock)] = adoptedSaved
                let adoptedDisplayed = Self.docked(adoptedSaved.displayed(available: available))
                if adoptedDisplayed != dock.dockLayout { dock.apply(adoptedDisplayed, render: true) }
            }
        }
        syncFloating()
        pool.removeAll()
        if save { scheduleSave() }
    }

    /// 窗口（nil 时为最近一次改动后）的保存停靠区，加上共享的浮动面板。
    func savedLayout(of dock: WindowDock?) -> DockLayout {
        var layout = dock.flatMap { savedLayouts[ObjectIdentifier($0)] } ?? current
        layout.floating = current.floating
        return layout
    }

    /// 窗口要写进会话的停靠区：保存布局，含当前不可用插件面板的位置（退出时插件先停，显示布局里已没有它们）。
    func persistedLayout(of dock: WindowDock) -> DockLayout {
        Self.docked(savedLayout(of: dock))
    }

    /// 去掉浮动面板，即窗口自己的停靠区。
    static func docked(_ layout: DockLayout) -> DockLayout {
        var layout = layout
        layout.floating = []
        return layout
    }

    // MARK: 面板实例

    func release(_ panel: any DockPanel, id: PanelID) {
        guard availablePanels.contains(id) else {
            panel.bind(to: nil)
            return
        }
        if pool[id] == nil { pool[id] = panel }
    }

    /// 本轮中刚离开别处的实例，或者按视图设置新建；设置无法解码时用默认设置，并显示错误。
    /// 面板作用于 `dock`，nil 时是浮动面板，作用于活动窗口；视图设置的改动记进同一处。
    func obtain(_ id: PanelID, settings: JSONValue?, for dock: WindowDock?) -> (any DockPanel)? {
        guard let type = DockPanels.type(id) else { return nil }
        let panel: any DockPanel
        if let pooled = pool.removeValue(forKey: id) {
            panel = pooled
        } else {
            let made = type.instantiate(settings)
            panel = made.panel
            if let error = made.error {
                logger.error("面板 \(id.rawValue, privacy: .public) 的视图设置无效：\(String(describing: error), privacy: .public)")
                problem = Problem(
                    title: String(localized: "layout.json 中“\(type.title)”的视图设置无效"),
                    detail: String(describing: error) + "\n" + String(localized: "已改用默认设置。")
                )
            }
        }
        panel.onSettingsChange = { [weak self, weak dock, weak panel] in
            guard let self, let panel else { return }
            perform(in: dock, render: false) { $0.settingSettings(panel.encodedSettings(), for: id) }
        }
        panel.bind(to: (dock ?? active)?.owner)
        return panel
    }

    // MARK: 浮动面板

    /// 更新浮动面板的置顶跟随状态；之后新建的浮动面板也会立即套用。
    func setKeepOnTop(_ on: Bool) {
        keepOnTop = on
        for window in floatingWindows.values {
            window.setKeepOnTop(on)
        }
    }

    private func syncFloating() {
        for item in current.displayed(available: availablePanels).floating {
            let window: FloatingPanelWindow
            if let existing = floatingWindows[item.panel] {
                window = existing
            } else {
                guard let type = DockPanels.type(item.panel), let panel = obtain(item.panel, settings: item.settings, for: nil) else { continue }
                window = FloatingPanelWindow(type: type, panel: panel, coordinator: self)
                window.setKeepOnTop(keepOnTop)
                floatingWindows[item.panel] = window
            }
            window.place(item.frame)
            let visible = !item.isHidden && active != nil
            if visible, !window.isVisible { window.orderFront(nil) }
            if !visible, window.isVisible { window.orderOut(nil) }
        }
    }

    func floatingMoved(_ panel: PanelID, to frame: DockFrame) {
        perform(in: nil, render: false) { $0.movingFloating(panel, to: frame) }
    }

    /// 浮动面板停靠回活动窗口中原来的区。
    func dockFloating(_ panel: PanelID) {
        guard let dock = active else { return }
        perform(in: dock) { $0.docking(panel) }
    }

    /// 停靠的面板拖出或经菜单成为浮动面板。`screenPoint` 是放下的位置，nil 时放在原来的区旁边。
    func float(_ panel: PanelID, from dock: WindowDock, at screenPoint: NSPoint?) {
        guard case let .docked(edge, _) = dock.dockLayout.placement(of: panel) else { return }
        let area = dock.dockLayout[edge]
        let size = edge == .bottom
            ? CGSize(width: 420, height: max(area.size, 200) + 28)
            : CGSize(width: max(area.size, 220), height: 400)
        let origin: CGPoint
        if let screenPoint {
            origin = CGPoint(x: screenPoint.x - 40, y: screenPoint.y - size.height + 14)
        } else {
            let view = dock.areas[edge]!
            let screen = view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
            origin = CGPoint(x: screen.minX + 40, y: screen.maxY - size.height - 40)
        }
        let frame = DockFrame(x: origin.x, y: origin.y, width: size.width, height: size.height)
        perform(in: dock) { $0.moving(panel, to: .floating(frame)) }
    }

    // MARK: 拖放

    func beginDrag(_ panel: PanelID, from dock: WindowDock?) {
        drag = (panel, dock)
    }

    /// 放进某个窗口的停靠区。来源是另一个窗口时，面板连同视图设置和实例从源窗口移过来；
    /// 目标窗口原来也停靠着它时，原来的实例让位（先摘下，再放入源窗口的实例）。
    func drop(into target: WindowDock, at destination: DockTarget) {
        guard let (panel, source) = drag else { return }
        guard let source, source !== target else {
            perform(in: target) { $0.moving(panel, to: destination) }
            return
        }
        let available = availablePanels
        let sourceSaved = savedLayout(of: source)
        let targetSaved = savedLayout(of: target)
        let sourceDisplayed = sourceSaved.displayed(available: available)
        let targetDisplayed = targetSaved.displayed(available: available)
        let nextSourceSaved = sourceDisplayed.removing(panel).merging(unavailableFrom: sourceSaved, available: available)
        let removedTargetSaved = targetDisplayed.removing(panel).merging(unavailableFrom: targetSaved, available: available)
        let insertedTargetSaved = targetDisplayed
            .inserting(panel, at: destination, settings: sourceDisplayed.settings(of: panel))
            .merging(unavailableFrom: targetSaved, available: available)
        commit([(source, nextSourceSaved), (target, removedTargetSaved), (target, insertedTargetSaved)], current: insertedTargetSaved)
    }

    /// 拖动结束而没有停靠区接收：停靠的面板变成浮动面板，浮动面板移到放下的位置。
    func endDrag(_ panel: PanelID, at screenPoint: NSPoint, accepted: Bool, cancelled: Bool) {
        defer { drag = nil }
        guard let drag, drag.panel == panel, !accepted, !cancelled else { return }
        if let source = drag.source {
            float(panel, from: source, at: screenPoint)
        } else if case let .floating(index) = current.placement(of: panel) {
            var frame = current.floating[index].frame
            (frame.x, frame.y) = (screenPoint.x - 40, screenPoint.y - frame.height + 14)
            perform(in: nil) { $0.movingFloating(panel, to: frame) }
        }
    }

    // MARK: 命令与菜单

    /// 停靠的面板在所在窗口中切换；浮动面板全应用切换（也是浮动面板的关闭按钮：隐藏，位置保留）。
    func togglePanel(_ type: DockPanelType, in dock: WindowDock?) {
        if case .floating = current.displayed(available: availablePanels).placement(of: type.id) {
            perform(in: nil) { $0.togglingPanel(type.id, defaultEdge: type.defaultEdge) }
        } else if let dock {
            perform(in: dock) { $0.togglingPanel(type.id, defaultEdge: type.defaultEdge) }
        }
    }

    /// 区头 ⋯ 菜单里的“面板”勾选项：列出全部登记的面板，勾选 = 作为标签显示在这个区。
    /// 勾上把面板放进这个区的末尾（原在别的区或浮动就移来）；取消即隐藏，位置保留。
    func panelToggles(for edge: DockEdge, in dock: WindowDock) -> [NSMenuItem] {
        DockPanels.all.map { type in
            let isHere = dock.dockLayout.visiblePanels(in: edge).contains(type.id)
            let item = MenuAction(type.title) { [weak self, weak dock] in
                guard let self, let dock else { return }
                setPanel(type.id, shownIn: edge, of: dock, !isHere)
            }.item
            item.state = isHere ? .on : .off
            return item
        }
    }

    private func setPanel(_ panel: PanelID, shownIn edge: DockEdge, of dock: WindowDock, _ shown: Bool) {
        perform(in: dock) { layout in
            let isHere = if case .docked(edge, _) = layout.placement(of: panel) { true } else { false }
            // 已在这个区（只是隐藏）时原位显示，否则放到这个区的末尾。
            if isHere { return layout.visiblePanels(in: edge).contains(panel) == shown ? layout : layout.togglingPanel(panel, defaultEdge: edge) }
            return shown ? layout.moving(panel, to: .area(edge, index: layout.visiblePanels(in: edge).count)) : layout
        }
    }

    /// 标签的右键菜单。停靠的面板（`dock` 是所在窗口）：移到其他区、浮动、隐藏；浮动面板：停靠到活动窗口的各区、隐藏。
    func menu(for panel: PanelID, in dock: WindowDock?) -> NSMenu {
        let menu = NSMenu()
        let current: DockEdge? = if case let .docked(edge, _) = dock?.dockLayout.placement(of: panel) { edge } else { nil }
        for edge in DockEdge.allCases where edge != current {
            let title = switch (edge, dock == nil) {
            case (.left, false): String(localized: "移到左侧")
            case (.right, false): String(localized: "移到右侧")
            case (.bottom, false): String(localized: "移到底部")
            case (.left, true): String(localized: "停靠到左侧")
            case (.right, true): String(localized: "停靠到右侧")
            case (.bottom, true): String(localized: "停靠到底部")
            }
            menu.addItem(MenuAction(title) { [weak self, weak dock] in
                guard let self, let target = dock ?? active else { return }
                perform(in: target) { $0.moving(panel, to: .area(edge, index: $0.visiblePanels(in: edge).count)) }
            }.item)
        }
        if let dock {
            menu.addItem(MenuAction(String(localized: "浮动")) { [weak self, weak dock] in
                guard let self, let dock else { return }
                float(panel, from: dock, at: nil)
            }.item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction(String(localized: "隐藏")) { [weak self, weak dock] in
            guard let self, let type = DockPanels.type(panel) else { return }
            togglePanel(type, in: dock)
        }.item)
        Theme.applyMenuFont(to: menu)
        return menu
    }

    // MARK: 布局方案

    enum SchemeError: LocalizedError, Equatable {
        case emptyName
        case duplicateName(String)
        case notFound(String)
        case storeUnavailable

        var errorDescription: String? {
            switch self {
            case .emptyName: String(localized: "方案名称不能为空")
            case .duplicateName: String(localized: "已有同名方案")
            case let .notFound(name): String(localized: "找不到布局方案“\(name)”")
            case .storeUnavailable: String(localized: "无法写入 layout-schemes.json")
            }
        }
    }

    var schemes: [LayoutScheme] {
        schemesStore?.value().schemes ?? []
    }

    func scheme(named name: String) -> LayoutScheme? {
        schemes.first { $0.name == name }
    }

    /// 把指定窗口（缺省为当前活动窗口）的停靠布局按名称保存到 `layout-schemes.json`；同名覆盖。
    func saveScheme(named rawName: String, from dock: WindowDock?) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SchemeError.emptyName }
        guard let schemesStore else { throw SchemeError.storeUnavailable }
        let snapshot = savedLayout(of: dock ?? active)
        try await schemesStore.update { file in
            if let index = file.schemes.firstIndex(where: { $0.name == name }) {
                file.schemes[index].layout = snapshot
            } else {
                file.schemes.append(LayoutScheme(name: name, layout: snapshot))
            }
        }
    }

    /// 改名布局方案；新名去首尾空白，空名或重名抛错。
    func renameScheme(_ old: String, to new: String) async throws {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SchemeError.emptyName }
        guard let schemesStore else { throw SchemeError.storeUnavailable }
        let currentSchemes = schemesStore.value().schemes
        guard currentSchemes.contains(where: { $0.name == old }) else {
            throw SchemeError.notFound(old)
        }
        if trimmed == old { return }
        guard !currentSchemes.contains(where: { $0.name == trimmed }) else {
            throw SchemeError.duplicateName(trimmed)
        }
        try await schemesStore.update { file in
            guard let index = file.schemes.firstIndex(where: { $0.name == old }),
                  !file.schemes.contains(where: { $0.name == trimmed }) else { return }
            file.schemes[index].name = trimmed
        }
    }

    /// 删除指定名称的布局方案。
    func deleteScheme(named name: String) async throws {
        guard let schemesStore else { throw SchemeError.storeUnavailable }
        try await schemesStore.update { file in
            file.schemes.removeAll { $0.name == name }
        }
    }

    /// 套用指定名称的布局方案到当前窗口，并立即持久化 `layout.json`。
    @discardableResult
    func applyScheme(named name: String, to dock: WindowDock?) async -> Bool {
        guard let scheme = scheme(named: name) else { return false }
        let known = availablePanels
        let targetLayout = scheme.layout.sanitized(knownPanels: known)
        let targetDock = dock ?? active
        commit(targetDock.map { [($0, targetLayout)] } ?? [], current: targetLayout, render: true, save: false)
        saveTask?.cancel()
        saveTask = nil
        await write()
        return true
    }

    // MARK: 保存

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            saveTask = nil
            await write()
        }
    }

    /// 退出前调用：有待保存的改动时立即写入。
    func flush() async {
        guard let task = saveTask else { return }
        task.cancel()
        saveTask = nil
        await write()
    }

    private func write() async {
        guard let store else { return }
        let value = current
        do {
            try await store.update { $0 = value }
        } catch {
            logger.error("无法保存 layout.json：\(String(describing: error), privacy: .public)")
            problem = Problem(title: String(localized: "无法保存 layout.json"), detail: ErrorText.describe(error))
        }
    }
}

/// 用闭包作动作的菜单项；菜单项持有它。
@MainActor
final class MenuAction: NSObject {
    private let action: () -> Void
    let item: NSMenuItem

    init(_ title: String, action: @escaping () -> Void) {
        self.action = action
        item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        super.init()
        item.target = self
        item.representedObject = self
    }

    @objc private func run(_ sender: Any?) {
        action()
    }
}

import AppKit
import MVFoundation
import MVIO
import MVSettings
import Observation

/// 设置窗口的数据：全局设置和路径规则的工作副本。
///
/// 改动立即反映在界面上，去抖后写入 `SettingsStore`；外部修改文件后从 `changes()` 收到并刷新。
@MainActor
@Observable
final class SettingsModel {
    private(set) var global: GlobalSettings = .default
    private(set) var rules: [PathRule] = []
    /// 写入失败或选择的目录无效时显示。
    private(set) var errorMessage: String?
    /// 浏览图缓存开关在下次启动生效；记下启动时的值，用来提示。
    private(set) var launchBrowseCacheEnabled: Bool?

    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let sources: any SourceRegistry
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var globalWrite: Task<Void, Never>?
    @ObservationIgnored private var rulesWrite: Task<Void, Never>?
    private static let writeDelay = Duration.milliseconds(150)

    let supportDirectory: URL
    let cacheDirectory: URL

    init(store: any SettingsStore, sources: any SourceRegistry, supportDirectory: URL, cacheDirectory: URL) {
        self.store = store
        self.sources = sources
        self.supportDirectory = supportDirectory
        self.cacheDirectory = cacheDirectory
        let changes = store.changes()
        changesTask = Task { [weak self] in
            await self?.loadAll()
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                switch change {
                case .global: if globalWrite == nil { global = await store.global() }
                case .pathRules: if rulesWrite == nil { rules = await store.pathRules() }
                default: break
                }
            }
        }
    }

    deinit {
        changesTask?.cancel()
    }

    func loadAll() async {
        global = await store.global()
        rules = await store.pathRules()
        if launchBrowseCacheEnabled == nil { launchBrowseCacheEnabled = global.cache.browseCacheEnabled }
    }

    // MARK: 全局

    func updateGlobal(_ change: (inout GlobalSettings) -> Void) {
        change(&global)
        globalWrite?.cancel()
        let value = global
        globalWrite = Task { [weak self, store] in
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled else { return }
            do {
                try await store.updateGlobal { $0 = value }
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = ErrorText.describe(error)
            }
            self?.globalWrite = nil
        }
    }

    /// 解码上限：太小时大图都走分块，下限 1024。
    func setMaxDecodeLongSide(_ value: Int) {
        updateGlobal { $0.maxDecodeLongSide = max(value, 1024) }
    }

    // MARK: 路径规则

    private func updateRules(_ change: (inout [PathRule]) -> Void) {
        change(&rules)
        rulesWrite?.cancel()
        let value = rules
        rulesWrite = Task { [weak self, store] in
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled else { return }
            do {
                try await store.updatePathRules { $0 = value }
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = ErrorText.describe(error)
            }
            self?.rulesWrite = nil
        }
    }

    /// 选目录新建规则。
    func addRule(folder url: URL) async -> UUID? {
        guard let prefix = await location(of: url) else { return nil }
        let rule = PathRule(name: url.lastPathComponent, prefix: prefix, settings: BookSettings())
        updateRules { $0.append(rule) }
        return rule.id
    }

    func setFolder(of id: UUID, to url: URL) async {
        guard let prefix = await location(of: url) else { return }
        updateRules { rules in
            if let index = rules.firstIndex(where: { $0.id == id }) { rules[index].prefix = prefix }
        }
    }

    private func location(of url: URL) async -> Location? {
        do {
            return try await sources.location(for: url)
        } catch {
            errorMessage = ErrorText.describe(error)
            return nil
        }
    }

    func rename(_ id: UUID, to name: String) {
        updateRules { rules in
            if let index = rules.firstIndex(where: { $0.id == id }) { rules[index].name = name }
        }
    }

    func delete(_ id: UUID) {
        updateRules { $0.removeAll { $0.id == id } }
    }

    func updateOverrides(of id: UUID, _ change: (inout BookSettings) -> Void) {
        updateRules { rules in
            if let index = rules.firstIndex(where: { $0.id == id }) { change(&rules[index].settings) }
        }
    }

    /// 列表的顺序：按路径，子目录的规则紧跟上级并缩进。
    var displayedRules: [(rule: PathRule, depth: Int)] {
        rules.sorted { $0.prefix.description.localizedStandardCompare($1.prefix.description) == .orderedAscending }.map { rule in
            (rule, PathRule.matching(rules, for: rule.prefix).filter { $0.id != rule.id && $0.prefix != rule.prefix }.count)
        }
    }

    /// 这条规则之下的上一层：全局加比它更一般的规则。
    private func layers(under rule: PathRule) -> [PathRule] {
        let matching = PathRule.matching(rules, for: rule.prefix)
        guard let index = matching.firstIndex(where: { $0.id == rule.id }) else { return matching }
        return Array(matching[..<index])
    }

    /// 上一层解析出的值。
    func inherited(by rule: PathRule) -> ResolvedBookSettings {
        layers(under: rule).reduce(global.defaultBook) { $0.applying($1.settings) }
    }

    /// 这条规则生效的值。
    func resolved(for rule: PathRule) -> ResolvedBookSettings {
        inherited(by: rule).applying(rule.settings)
    }

    /// 这一项的继承来源：离这条规则最近、设了这一项的上层规则，否则是全局。
    func origin(of field: OverrideField, in rule: PathRule) -> String {
        let value = field.text(inherited(by: rule))
        if let source = layers(under: rule).last(where: { field.isSet($0.settings) }) {
            return String(localized: "规则「\(source.name)」：\(value)")
        }
        return String(localized: "全局：\(value)")
    }
}

/// 规则可以覆盖的一项。
@MainActor
struct OverrideField: Identifiable {
    enum Control {
        case choice([(title: String, apply: (inout BookSettings) -> Void)])
        case toggle(get: (ResolvedBookSettings) -> Bool, set: (inout BookSettings, Bool) -> Void)
    }

    let id: String
    let title: String
    let isSet: (BookSettings) -> Bool
    let clear: (inout BookSettings) -> Void
    /// 新加覆盖项时用上一层的值。
    let seed: (inout BookSettings, ResolvedBookSettings) -> Void
    let text: (ResolvedBookSettings) -> String
    let control: Control

    private static func `enum`<Value: Equatable>(
        _ id: String, _ title: String, _ path: WritableKeyPath<BookSettings, Value?>, _ resolved: KeyPath<ResolvedBookSettings, Value>,
        _ options: [(String, Value)]
    ) -> OverrideField {
        OverrideField(
            id: id, title: title, isSet: { $0[keyPath: path] != nil }, clear: { $0[keyPath: path] = nil },
            seed: { $0[keyPath: path] = $1[keyPath: resolved] },
            text: { settings in options.first { $0.1 == settings[keyPath: resolved] }?.0 ?? "" },
            control: .choice(options.map { option in (option.0, { $0[keyPath: path] = option.1 }) })
        )
    }

    private static func bool(_ id: String, _ title: String, _ path: WritableKeyPath<BookSettings, Bool?>, _ resolved: KeyPath<ResolvedBookSettings, Bool>, inverted: Bool = false) -> OverrideField {
        OverrideField(
            id: id, title: title, isSet: { $0[keyPath: path] != nil }, clear: { $0[keyPath: path] = nil },
            seed: { $0[keyPath: path] = $1[keyPath: resolved] },
            text: { ($0[keyPath: resolved] != inverted) ? String(localized: "开") : String(localized: "关") },
            control: .toggle(get: { $0[keyPath: resolved] != inverted }, set: { $0[keyPath: path] = $1 != inverted })
        )
    }

    static let browseModes: [(String, BrowseMode)] = [
        (String(localized: "分页"), .paged), (String(localized: "瀑布流"), .waterfall),
        (String(localized: "纵向连续"), .verticalStrip), (String(localized: "横向连续"), .horizontalStrip),
    ]
    static let pageModes: [(String, PageMode)] = [(String(localized: "单页"), .single), (String(localized: "双页"), .double)]
    static let directions: [(String, ReadingDirection)] = [(String(localized: "左开"), .leftToRight), (String(localized: "右开"), .rightToLeft)]
    static let widePages: [(String, WidePagePolicy)] = [(String(localized: "照常配对"), .asIs), (String(localized: "单独成帧"), .single), (String(localized: "拆成两页"), .split)]
    static let scaleModes: [(String, ScaleMode)] = ScaleMode.allModes.map { (ViewerHUD.title(of: $0), $0) }
    static let sortKeys: [(String, SortKey)] = [SortKey.name, .modified, .created, .size, .type, .random].map { (SortMenu.title($0), $0) }
    static let resamples: [(String, ResampleFilter)] = [("Lanczos", .lanczos), (String(localized: "最近邻"), .nearest)]

    static let all: [OverrideField] = [
        .enum("browseMode", String(localized: "浏览方式"), \.browseMode, \.browseMode, browseModes),
        .enum("pageMode", String(localized: "单双页"), \.pageMode, \.pageMode, pageModes),
        .enum("direction", String(localized: "阅读方向"), \.direction, \.direction, directions),
        .bool("firstPageSingle", String(localized: "首页单页"), \.firstPageSingle, \.firstPageSingle),
        .enum("widePage", String(localized: "宽页"), \.widePage, \.widePage, widePages),
        OverrideField(
            id: "sort", title: String(localized: "页面排序"), isSet: { $0.sort != nil }, clear: { $0.sort = nil },
            seed: { $0.sort = $1.sort },
            text: { SortMenu.title($0.sort.key) },
            control: .choice(sortKeys.map { option in (option.0, { $0.sort = SortSpec(key: option.1, ascending: $0.sort?.ascending ?? true, foldersFirst: $0.sort?.foldersFirst ?? true) }) })
        ),
        OverrideField(
            id: "recursion", title: String(localized: "递归展开"), isSet: { $0.recursion != nil }, clear: { $0.recursion = nil },
            seed: { $0.recursion = $1.recursion },
            text: { $0.recursion.enabled ? String(localized: "开") : String(localized: "关") },
            control: .toggle(get: { $0.recursion.enabled }, set: { settings, value in
                settings.recursion = RecursionSpec(enabled: value, maxDepth: settings.recursion?.maxDepth ?? 1)
            })
        ),
        .enum("scaleMode", String(localized: "缩放方式"), \.scaleMode, \.scaleMode, scaleModes),
        .bool("shrinkOnly", String(localized: "仅缩小"), \.allowUpscale, \.allowUpscale, inverted: true),
        .bool("keepZoom", String(localized: "保持缩放"), \.keepZoomOnPageTurn, \.keepZoomOnPageTurn),
        .enum("resample", String(localized: "重采样"), \.resample, \.resample, resamples),
    ]
}

extension ScaleMode {
    static let allModes: [ScaleMode] = [.fitWindow, .fitWidth, .fitHeight, .fill, .original, .devicePixel, .fixed]
}

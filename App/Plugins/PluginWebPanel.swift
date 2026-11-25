import AppKit
import CoreServices
import Foundation
import MVFoundation
import MVLayout
import MVPlugins
import MVScripting
import MVServices
import MVSettings
import WebKit

/// 面板持有的插件声明、目录与有效权限快照；任一字段变化即触发重建。
struct PluginPanelSnapshot: Equatable, Sendable {
    var pluginID: String
    var pluginName: String
    var directory: URL
    var declaration: PluginPanelDeclaration
    var permissions: Set<PluginPermission>
}

/// 插件网页面板宿主：承载单个插件声明的 HTML/JS 页面。
@MainActor
final class PluginWebPanel: DockPanel {
    struct Settings: Codable {}

    let panelID: PanelID
    private(set) var snapshot: PluginPanelSnapshot
    private let services: CoreServices

    let settings = Settings()
    var onSettingsChange: (() -> Void)?

    private let containerView = PluginPanelContainerView()
    private let statusOverlay = PluginPanelStatusOverlay()
    private(set) var webView: WKWebView?
    private var navigationProxy: NavigationProxy?
    private var bridgeProxy: BridgeProxy?

    private weak var boundWindow: ReaderWindowController?
    private var pageGeneration: UInt64 = 0
    private var bindGeneration: UInt64 = 0
    private var isPageReady = false
    private(set) var isUnresponsive = false
    private(set) var errorMessage: String?
    private var isVisibleOnScreen = false

    private var probeInFlight = false
    private var probeToken: UInt64 = 0
    private var probeTimeoutTask: Task<Void, Never>?

    private var fileWatcher: PluginDirectoryWatcher?
    private var fileReloadTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var themeObservers: [NSObjectProtocol] = []

    private let eventQueue = PluginPanelEventQueue()

    var view: NSView { containerView }
    var boundSession: SessionID? { boundWindow?.session.id }

    #if DEBUG
    var debugPageGeneration: UInt64 { pageGeneration }
    var debugReloadButton: NSButton { statusOverlay.reloadButton }
    var debugIsPageReady: Bool { isPageReady }
    #endif

    init(plugin: PluginInfo, panel: PluginPanelDeclaration, services: CoreServices) {
        self.panelID = PanelID("plugin.\(plugin.id).\(panel.id)")
        self.services = services
        let granted = services.pluginSettings?.value().plugins[plugin.id]?.grantedPermissions ?? []
        let declared = Set(plugin.manifest?.permissions ?? [])
        self.snapshot = PluginPanelSnapshot(
            pluginID: plugin.id,
            pluginName: plugin.manifest?.name ?? plugin.id,
            directory: plugin.directory,
            declaration: panel,
            permissions: declared.intersection(granted)
        )

        setupViews()
        setupEventQueue()
        setupObservers()
        startFileWatcher(for: snapshot.directory)
        rebuild()
    }

    isolated deinit {
        PluginPanelEventHub.shared.clearSubscriptions(for: self)
        cancelTimersAndTasks()
        fileWatcher?.stop()
        fileWatcher = nil
        for observer in themeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        themeObservers.removeAll()
        teardownWebView()
    }

    // MARK: - DockPanel

    func bind(to window: ReaderWindowController?) {
        let previousSession = boundWindow?.session.id
        let nextSession = window?.session.id
        let changed = (boundWindow !== window) || (previousSession != nextSession)
        guard changed else { return }

        bindGeneration &+= 1
        eventQueue.clearPending()
        boundWindow = window

        if PluginPanelEventHub.shared.isSubscribed(self, to: .targetChanged), !isUnresponsive {
            eventQueue.enqueue(
                event: .targetChanged,
                payload: ["hasWindow": .bool(window != nil)],
                bindGeneration: bindGeneration
            )
        }
    }

    func addOptions(to menu: NSMenu) {
        menu.addItem(MenuAction(String(localized: "重新载入")) { [weak self] in
            self?.rebuild()
        }.item)
    }

    // MARK: - 快照更新与重建

    /// 由 `PluginCoordinator` 在清单或权限变化时调用；快照内容任一改变即重建。
    func updateSnapshot(_ next: PluginPanelSnapshot) {
        guard next != snapshot else { return }
        let directoryChanged = next.directory != snapshot.directory
        snapshot = next
        if directoryChanged {
            startFileWatcher(for: next.directory)
        }
        rebuild()
    }

    /// 丢弃旧 `WKWebView`，用新的 configuration 与非持久数据存储重建并重新载入入口页。
    func rebuild() {
        pageGeneration &+= 1
        let gen = pageGeneration

        cancelProbe()
        fileReloadTask?.cancel()
        fileReloadTask = nil
        rebuildTask?.cancel()
        rebuildTask = nil
        isPageReady = false
        isUnresponsive = false
        errorMessage = nil
        statusOverlay.hide()

        PluginPanelEventHub.shared.clearSubscriptions(for: self)
        eventQueue.resetForRebuild()
        teardownWebView()

        let currentSnapshot = snapshot
        rebuildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ruleList: WKContentRuleList?
            if currentSnapshot.permissions.contains(.network) {
                ruleList = nil
            } else {
                do {
                    ruleList = try await Self.networkBlockRuleList()
                } catch {
                    guard !Task.isCancelled, self.pageGeneration == gen else { return }
                    let detail = ErrorText.describe(error)
                    self.showError(String(localized: "无法安装网络限制规则：\(detail)"))
                    return
                }
            }
            guard !Task.isCancelled, self.pageGeneration == gen else { return }
            self.mountNewWebView(snapshot: currentSnapshot, generation: gen, networkBlockRule: ruleList)
        }
    }

    // MARK: - 事件投递接线

    func enqueueEvent(_ event: PluginPanelEventName, payload: [String: JSONValue]) {
        guard !isUnresponsive else { return }
        eventQueue.enqueue(event: event, payload: payload, bindGeneration: bindGeneration)
    }

    private func setupEventQueue() {
        eventQueue.deliver = { [weak self] item, completion in
            guard let self else { completion(); return }
            guard item.bindGeneration == self.bindGeneration,
                  !self.isUnresponsive,
                  self.isPageReady,
                  let webView = self.webView else {
                completion()
                return
            }
            let gen = self.pageGeneration
            self.probeResponsiveness()
            let eventLiteral = Self.jsonLiteral(.string(item.event.rawValue))
            let payloadLiteral = Self.jsonLiteral(.object(item.payload))
            let script = "window.__mvDispatchEvent && window.__mvDispatchEvent(\(eventLiteral), \(payloadLiteral));"
            self.runJavaScript(script, on: webView) { [weak self] _, _ in
                guard let self, self.pageGeneration == gen else { return }
                completion()
            }
        }
    }

    // MARK: - 视图与主题同步

    private func setupViews() {
        statusOverlay.onReload = { [weak self] in
            self?.rebuild()
        }
        statusOverlay.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.isHidden = true
        containerView.addSubview(statusOverlay)
        NSLayoutConstraint.activate([
            statusOverlay.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            statusOverlay.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            statusOverlay.topAnchor.constraint(equalTo: containerView.topAnchor),
            statusOverlay.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        containerView.onEffectiveAppearanceChange = { [weak self] in
            self?.applyThemeVariables()
        }
        containerView.onVisibilityChange = { [weak self] visible in
            self?.handleVisibilityChanged(visible)
        }
    }

    private func setupObservers() {
        let center = NotificationCenter.default
        themeObservers.append(center.addObserver(
            forName: Theme.fontsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyThemeVariables()
            }
        })
        themeObservers.append(center.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyThemeVariables()
            }
        })
    }

    private func handleVisibilityChanged(_ visible: Bool) {
        let wasVisible = isVisibleOnScreen
        isVisibleOnScreen = visible
        if !visible {
            cancelProbe()
            fileReloadTask?.cancel()
            fileReloadTask = nil
        } else if !wasVisible, isPageReady, !isUnresponsive {
            probeResponsiveness()
        }
    }

    private func themeVariablesJSON() -> String {
        let appearance = webView?.effectiveAppearance
            ?? containerView.window?.effectiveAppearance
            ?? containerView.effectiveAppearance
        var resolvedAccent = Theme.accent
        appearance.performAsCurrentDrawingAppearance {
            resolvedAccent = Theme.accent.usingColorSpace(.sRGB) ?? Theme.accent
        }
        let r = Int((resolvedAccent.redComponent * 255).rounded())
        let g = Int((resolvedAccent.greenComponent * 255).rounded())
        let b = Int((resolvedAccent.blueComponent * 255).rounded())
        let accentHex = String(format: "#%02x%02x%02x", min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))

        let spec = Theme.fonts[.panels]
        let fontFamily: String
        if let rawFamily = spec?.family?.trimmingCharacters(in: .whitespacesAndNewlines), !rawFamily.isEmpty {
            let escaped = rawFamily.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            fontFamily = "\"\(escaped)\", -apple-system, BlinkMacSystemFont, sans-serif"
        } else {
            fontFamily = "-apple-system, BlinkMacSystemFont, sans-serif"
        }

        let sizeValue = spec?.size ?? Double(Theme.defaultSize(.panels))
        let fontSize: String
        if sizeValue.rounded() == sizeValue {
            fontSize = "\(Int(sizeValue))px"
        } else {
            fontSize = "\(sizeValue)px"
        }

        return Self.jsonLiteral(.object([
            "accent": .string(accentHex),
            "fontFamily": .string(fontFamily),
            "fontSize": .string(fontSize),
        ]))
    }

    private func applyThemeVariables() {
        guard let webView, isPageReady, !isUnresponsive else { return }
        let script = "window.__mvApplyTheme && window.__mvApplyTheme(\(themeVariablesJSON()));"
        runJavaScript(script, on: webView) { _, _ in }
    }

    // MARK: - WKWebView 构建与卸载

    private func mountNewWebView(
        snapshot: PluginPanelSnapshot,
        generation: UInt64,
        networkBlockRule: WKContentRuleList?
    ) {
        guard let entryURL = Self.entryURL(pluginID: snapshot.pluginID, entry: snapshot.declaration.entry) else {
            showError(String(localized: "面板入口地址无效：\(snapshot.declaration.entry)"))
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let schemeHandler = PluginSchemeHandler(pluginID: snapshot.pluginID, directory: snapshot.directory)
        config.setURLSchemeHandler(schemeHandler, forURLScheme: Self.scheme)

        let controller = config.userContentController
        if let networkBlockRule {
            controller.add(networkBlockRule)
        }

        let bridge = BridgeProxy(panel: self, generation: generation)
        controller.addScriptMessageHandler(bridge, contentWorld: .page, name: Self.bridgeName)
        bridgeProxy = bridge

        let shimScript = WKUserScript(
            source: Self.injectedShimSource(initialThemeJSON: themeVariablesJSON()),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(shimScript)

        let webView = WKWebView(frame: containerView.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.isInspectable = true

        let navProxy = NavigationProxy(panel: self, generation: generation, pluginID: snapshot.pluginID)
        webView.navigationDelegate = navProxy
        webView.uiDelegate = navProxy
        navigationProxy = navProxy

        containerView.addSubview(webView, positioned: .below, relativeTo: statusOverlay)
        self.webView = webView

        webView.load(URLRequest(url: entryURL))
    }

    private func teardownWebView() {
        guard let old = webView else { return }
        webView = nil
        navigationProxy = nil
        bridgeProxy = nil
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.stopLoading()
        old.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName, contentWorld: .page)
        old.configuration.userContentController.removeAllUserScripts()
        old.configuration.userContentController.removeAllContentRuleLists()
        old.removeFromSuperview()
    }

    private func cancelTimersAndTasks() {
        cancelProbe()
        fileReloadTask?.cancel()
        fileReloadTask = nil
        rebuildTask?.cancel()
        rebuildTask = nil
    }

    // MARK: - 卡死检测与错误展示

    /// 同步 `@MainActor` 小函数发起带回调的 `evaluateJavaScript`（避免 Swift 6 async 诊断）。
    private func runJavaScript(
        _ script: String,
        on webView: WKWebView,
        completion: @escaping @MainActor (Any?, (any Error)?) -> Void
    ) {
        webView.evaluateJavaScript(script) { value, error in
            MainActor.assumeIsolated {
                completion(value, error)
            }
        }
    }

    /// 发起一次单次响应探测（3 秒无回调判为无响应），每个实例同时至多一个未完成探测。
    func probeResponsiveness() {
        guard isPageReady, !isUnresponsive, !probeInFlight,
              let webView, containerView.window != nil, !containerView.isHiddenOrHasHiddenAncestor else {
            return
        }
        probeInFlight = true
        probeToken &+= 1
        let token = probeToken
        let gen = pageGeneration

        probeTimeoutTask?.cancel()
        probeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self,
                  self.pageGeneration == gen,
                  self.probeToken == token,
                  self.probeInFlight else {
                return
            }
            self.markUnresponsive()
        }

        runJavaScript("40+2", on: webView) { [weak self] _, _ in
            guard let self, self.pageGeneration == gen, self.probeToken == token else { return }
            self.probeInFlight = false
            self.probeTimeoutTask?.cancel()
            self.probeTimeoutTask = nil
        }
    }

    private func cancelProbe() {
        probeInFlight = false
        probeToken &+= 1
        probeTimeoutTask?.cancel()
        probeTimeoutTask = nil
    }

    private func markUnresponsive() {
        probeInFlight = false
        probeTimeoutTask?.cancel()
        probeTimeoutTask = nil
        isUnresponsive = true
        eventQueue.setPaused(true)
        let reason = String(localized: "网页无响应") + "\n" + String(localized: "卡住的网页进程会在退出 App 后释放")
        showError(reason)
    }

    private func showError(_ message: String) {
        errorMessage = message
        statusOverlay.show(message: message)
    }

    // MARK: - 文件监视（FSEvents，300 ms 去抖）

    private func startFileWatcher(for directory: URL) {
        fileWatcher?.stop()
        fileReloadTask?.cancel()
        fileReloadTask = nil
        fileWatcher = PluginDirectoryWatcher(directory: directory) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleFileReload()
            }
        }
    }

    private func scheduleFileReload() {
        guard containerView.window != nil, !containerView.isHiddenOrHasHiddenAncestor else { return }
        fileReloadTask?.cancel()
        fileReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.fileReloadTask = nil
            self.rebuild()
        }
    }

    // MARK: - 导航与桥回调

    fileprivate func handleDidFinish(webView: WKWebView, generation: UInt64) {
        guard generation == pageGeneration, webView === self.webView else { return }
        isPageReady = true
        applyThemeVariables()
        eventQueue.setPaused(false)
    }

    fileprivate func handleNavigationFailure(webView: WKWebView, generation: UInt64, error: any Error) {
        guard generation == pageGeneration, webView === self.webView else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        cancelProbe()
        eventQueue.setPaused(true)
        showError(String(localized: "页面载入失败：\(nsError.localizedDescription)"))
    }

    fileprivate func handleProcessTerminated(webView: WKWebView, generation: UInt64) {
        guard generation == pageGeneration, webView === self.webView else { return }
        cancelProbe()
        isPageReady = false
        eventQueue.setPaused(true)
        showError(String(localized: "网页进程已意外终止"))
    }

    fileprivate func handleBridgeMessage(_ message: WKScriptMessage, generation: UInt64) async -> (Any?, String?) {
        // 来源核对：主框架、本插件的 macview-plugin 来源、当前这一代页面。
        guard generation == pageGeneration,
              message.webView === self.webView,
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol.lowercased() == Self.scheme,
              message.frameInfo.securityOrigin.host.lowercased() == snapshot.pluginID.lowercased() else {
            return (nil, String(localized: "拒绝来自无效来源的消息"))
        }

        // 在任何 await 前把消息体转换成值类型并固定上下文。
        let payload = Self.jsonValue(from: message.body)
        guard case let .object(dict) = payload,
              case let .string(kind) = dict["kind"] else {
            return (nil, String(localized: "桥消息格式无效"))
        }

        switch kind {
        case "subscribe":
            guard case let .string(rawEvent) = dict["event"],
                  let event = PluginPanelEventName(rawValue: rawEvent) else {
                return (nil, String(localized: "未知事件"))
            }
            PluginPanelEventHub.shared.subscribe(self, event: event)
            return (NSNull(), nil)

        case "unsubscribe":
            guard case let .string(rawEvent) = dict["event"],
                  let event = PluginPanelEventName(rawValue: rawEvent) else {
                return (nil, String(localized: "未知事件"))
            }
            PluginPanelEventHub.shared.unsubscribe(self, event: event)
            return (NSNull(), nil)

        case "log":
            let levelRaw = if case let .string(s) = dict["level"] { s } else { "info" }
            let text = if case let .string(s) = dict["text"] { s } else { "" }
            let level: ScriptLogEntry.Level = switch levelRaw {
            case "error": .error
            case "warning", "warn": .warning
            default: .info
            }
            services.pluginHost?.log.append(source: snapshot.pluginName, level: level, text: text)
            return (NSNull(), nil)

        case "call":
            guard case let .string(rawMethod) = dict["method"],
                  let method = ScriptAPI.Method(rawValue: rawMethod) else {
                return (nil, String(localized: "未知的面板方法"))
            }
            let args: [JSONValue] = if case let .array(arr) = dict["args"] { arr } else { [] }
            guard let host = services.pluginHost else {
                return (nil, String(localized: "插件宿主不可用"))
            }
            let pluginID = snapshot.pluginID
            let callContext = snapshotCallContext()
            do {
                let result = try await host.panelCall(
                    plugin: pluginID,
                    method: method,
                    params: args,
                    context: callContext
                )
                return (Self.bridgeObject(from: result), nil)
            } catch {
                return (nil, error.localizedDescription)
            }

        default:
            return (nil, String(localized: "未知的桥消息类型"))
        }
    }

    /// 调用开始时同步固定作用窗口与选择快照，来源与从该窗口执行脚本命令一致。
    private func snapshotCallContext() -> ScriptCallContext {
        let window = boundWindow
        let locations = Self.selectionSnapshot(for: window)
        return ScriptCallContext(
            caller: "plugin:\(snapshot.pluginID)",
            callerName: snapshot.pluginName,
            session: window?.session.id,
            selection: locations.map(ScriptLocationCodec.token(for:))
        )
    }

    private static func selectionSnapshot(for controller: ReaderWindowController?) -> [Location] {
        guard let controller else { return [] }
        let key = NSApp.keyWindow
        let responder = (key === controller.window || key is FloatingPanelWindow)
            ? key?.firstResponder
            : controller.window?.firstResponder
        if let view = responder as? NSView {
            let panels = Array(controller.dock.panels.values) + controller.dock.coordinator.floatingWindows.values.map(\.panel)
            for case let panel as CollectionPanel in panels where panel.owner === controller && view.isDescendant(of: panel.view) {
                if !panel.targetEntries.isEmpty {
                    return panel.targetEntries.map(\.location)
                }
            }
        }
        if let pages = controller.session.book?.pages,
           pages.indices.contains(controller.session.currentPage) {
            return [pages[controller.session.currentPage].id]
        }
        return []
    }

    // MARK: - 静态工具与规则编译

    private static let scheme = "macview-plugin"
    private static let bridgeName = "mv"
    private static let blockNetworkRuleIdentifier = "macview.plugin.block-network"
    private static let blockNetworkRuleJSON = """
    [
      {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}
    ]
    """
    private static var cachedBlockNetworkRule: WKContentRuleList?

    private static func networkBlockRuleList() async throws -> WKContentRuleList {
        if let cached = cachedBlockNetworkRule {
            return cached
        }
        let store = WKContentRuleListStore.default()
        guard let store else {
            throw NSError(domain: "MacView.PluginWebPanel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "内容规则存储不可用"),
            ])
        }
        let compiled = try await store.compileContentRuleList(
            forIdentifier: blockNetworkRuleIdentifier,
            encodedContentRuleList: blockNetworkRuleJSON
        )
        guard let compiled else {
            throw NSError(domain: "MacView.PluginWebPanel", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "编译网络限制规则失败"),
            ])
        }
        cachedBlockNetworkRule = compiled
        return compiled
    }

    private static func entryURL(pluginID: String, entry: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = pluginID
        components.path = entry.hasPrefix("/") ? entry : "/" + entry
        return components.url
    }

    private static func jsonLiteral(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }

    private static func jsonValue(from any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let value = number.doubleValue
            return value.isFinite ? .number(value) : .null
        }
        if let string = any as? String { return .string(string) }
        if let array = any as? [Any] { return .array(array.map(jsonValue(from:))) }
        if let dict = any as? [String: Any] { return .object(dict.mapValues(jsonValue(from:))) }
        return .null
    }

    private static func bridgeObject(from value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case let .bool(b): NSNumber(value: b)
        case let .number(n): NSNumber(value: n)
        case let .string(s): s
        case let .array(items): items.map(bridgeObject(from:))
        case let .object(dict): dict.mapValues(bridgeObject(from:))
        }
    }

    private static func injectedShimSource(initialThemeJSON: String) -> String {
        """
        (function() {
          "use strict";
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mv;
          if (!handler) return;

          const BRIDGE_ERROR_MARK = Symbol("mv.bridgeError");
          const VALID_EVENTS = new Set(["bookOpened", "pageChanged", "pageEnd", "windowStateChanged", "targetChanged"]);
          const listeners = new Map();

          function formatPart(arg) {
            if (arg instanceof Error) {
              const header = (arg.name || "Error") + (arg.message ? ": " + arg.message : "");
              if (arg.stack) {
                const stack = String(arg.stack);
                return stack.startsWith(header) ? stack : (header + "\\n" + stack);
              }
              return header;
            }
            if (typeof arg === "string") return arg;
            if (arg === undefined) return "undefined";
            if (arg === null) return "null";
            try { return JSON.stringify(arg); } catch (_) { return String(arg); }
          }

          function sendLog(level, text) {
            try {
              handler.postMessage({ kind: "log", level: level, text: String(text) }).catch(() => {});
            } catch (_) {}
          }

          function callBridge(method, rawArgs) {
            const args = Array.prototype.slice.call(rawArgs);
            while (args.length > 0 && args[args.length - 1] === undefined) {
              args.pop();
            }
            const sanitized = args.map(v => v === undefined ? null : v);
            return handler.postMessage({ kind: "call", method: method, args: sanitized }).catch(err => {
              const wrapped = err instanceof Error ? err : new Error(String(err));
              try { wrapped[BRIDGE_ERROR_MARK] = true; } catch (_) {}
              throw wrapped;
            });
          }

          const mv = {};
          for (const name of ["book", "page", "pages", "selection", "command", "goTo", "open", "toast", "confirm", "prompt"]) {
            mv[name] = function() {
              return callBridge(name, arguments);
            };
          }
          mv.storage = {
            get: function() { return callBridge("storageGet", arguments); },
            set: function() { return callBridge("storageSet", arguments); },
            remove: function() { return callBridge("storageRemove", arguments); }
          };
          mv.on = function(event, fn) {
            if (typeof event !== "string" || !VALID_EVENTS.has(event) || typeof fn !== "function") {
              return Promise.resolve();
            }
            let set = listeners.get(event);
            const first = !set || set.size === 0;
            if (!set) {
              set = new Set();
              listeners.set(event, set);
            }
            set.add(fn);
            if (first) {
              return handler.postMessage({ kind: "subscribe", event: event }).then(() => undefined);
            }
            return Promise.resolve();
          };
          mv.off = function(event, fn) {
            if (typeof event !== "string" || !VALID_EVENTS.has(event)) {
              return Promise.resolve();
            }
            const set = listeners.get(event);
            if (!set || !set.has(fn)) {
              return Promise.resolve();
            }
            set.delete(fn);
            if (set.size === 0) {
              listeners.delete(event);
              return handler.postMessage({ kind: "unsubscribe", event: event }).then(() => undefined);
            }
            return Promise.resolve();
          };

          Object.defineProperty(window, "mv", {
            value: mv,
            configurable: false,
            writable: false,
            enumerable: true
          });

          Object.defineProperty(window, "__mvDispatchEvent", {
            value: function(event, payload) {
              const set = listeners.get(event);
              if (!set || set.size === 0) return;
              for (const fn of Array.from(set)) {
                try {
                  const ret = fn(payload);
                  if (ret && typeof ret.catch === "function") {
                    ret.catch(err => {
                      if (err && err[BRIDGE_ERROR_MARK]) return;
                      sendLog("error", formatPart(err));
                    });
                  }
                } catch (err) {
                  if (!(err && err[BRIDGE_ERROR_MARK])) {
                    sendLog("error", formatPart(err));
                  }
                }
              }
            },
            configurable: false,
            writable: false,
            enumerable: false
          });

          function applyTheme(vars) {
            const root = document.documentElement;
            if (!root) {
              document.addEventListener("DOMContentLoaded", function() { applyTheme(vars); }, { once: true });
              return;
            }
            root.style.setProperty("--mv-accent", vars.accent);
            root.style.setProperty("--mv-font-family", vars.fontFamily);
            root.style.setProperty("--mv-font-size", vars.fontSize);
          }

          Object.defineProperty(window, "__mvApplyTheme", {
            value: applyTheme,
            configurable: false,
            writable: false,
            enumerable: false
          });
          applyTheme(\(initialThemeJSON));

          for (const pair of [["log", "info"], ["info", "info"], ["warn", "warning"], ["error", "error"]]) {
            const method = pair[0];
            const level = pair[1];
            const original = console[method];
            console[method] = function() {
              const text = Array.prototype.map.call(arguments, formatPart).join(" ");
              sendLog(level, text);
              if (typeof original === "function") {
                return original.apply(console, arguments);
              }
            };
          }

          window.addEventListener("error", function(ev) {
            const msg = ev && ev.error ? formatPart(ev.error) : (ev && ev.message ? ev.message : "Script error");
            sendLog("error", msg);
          });

          window.addEventListener("unhandledrejection", function(ev) {
            const reason = ev ? ev.reason : undefined;
            if (reason && reason[BRIDGE_ERROR_MARK]) return;
            sendLog("error", formatPart(reason));
          });
        })();
        """
    }
}

// MARK: - 桥与导航代理（弱引用宿主，避免 WKUserContentController 循环引用）

@MainActor
private final class BridgeProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var panel: PluginWebPanel?
    let generation: UInt64

    init(panel: PluginWebPanel, generation: UInt64) {
        self.panel = panel
        self.generation = generation
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let panel else {
            return (nil, String(localized: "面板已关闭"))
        }
        return await panel.handleBridgeMessage(message, generation: generation)
    }
}

@MainActor
private final class NavigationProxy: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var panel: PluginWebPanel?
    let generation: UInt64
    let pluginID: String

    init(panel: PluginWebPanel, generation: UInt64, pluginID: String) {
        self.panel = panel
        self.generation = generation
        self.pluginID = pluginID.lowercased()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url,
              url.scheme?.lowercased() == "macview-plugin",
              url.host?.lowercased() == pluginID else {
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        panel?.handleDidFinish(webView: webView, generation: generation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        panel?.handleNavigationFailure(webView: webView, generation: generation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        panel?.handleNavigationFailure(webView: webView, generation: generation, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        panel?.handleProcessTerminated(webView: webView, generation: generation)
    }
}

// MARK: - 自定义 Scheme 处理（仅读本插件目录）

@MainActor
private final class PluginSchemeHandler: NSObject, WKURLSchemeHandler {
    private let pluginID: String
    private let rootDirectory: URL
    private let rootPrefix: String

    init(pluginID: String, directory: URL) {
        self.pluginID = pluginID.lowercased()
        let resolvedRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        self.rootDirectory = resolvedRoot
        let path = resolvedRoot.path(percentEncoded: false)
        self.rootPrefix = path.hasSuffix("/") ? path : path + "/"
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            finish(urlSchemeTask, url: URL(string: "macview-plugin://invalid/")!, status: 403)
            return
        }
        guard url.scheme?.lowercased() == "macview-plugin",
              url.host?.lowercased() == pluginID else {
            finish(urlSchemeTask, url: url, status: 403)
            return
        }

        let decodedPath = url.path(percentEncoded: false)
        let relative = decodedPath.hasPrefix("/") ? String(decodedPath.dropFirst()) : decodedPath
        guard !relative.isEmpty else {
            finish(urlSchemeTask, url: url, status: 403)
            return
        }

        let candidate = rootDirectory.appending(path: relative)
        let standardized = candidate.standardizedFileURL.path(percentEncoded: false)
        guard standardized.hasPrefix(rootPrefix) else {
            finish(urlSchemeTask, url: url, status: 403)
            return
        }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        guard resolved.hasPrefix(rootPrefix) else {
            finish(urlSchemeTask, url: url, status: 403)
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else {
            finish(urlSchemeTask, url: url, status: 404)
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else {
            finish(urlSchemeTask, url: url, status: 404)
            return
        }

        let mime = Self.mimeType(forExtension: URL(fileURLWithPath: resolved).pathExtension.lowercased())
        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-store",
        ]
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } else {
            finish(urlSchemeTask, url: url, status: 500)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func finish(_ task: any WKURLSchemeTask, url: URL, status: Int) {
        let headers = [
            "Content-Type": "text/plain; charset=utf-8",
            "Content-Length": "0",
            "Cache-Control": "no-store",
        ]
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
            task.didReceive(response)
            task.didReceive(Data())
            task.didFinish()
        } else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNoPermissionsToReadFile))
        }
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}

// MARK: - 容器与错误状态视图

@MainActor
private final class PluginPanelContainerView: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onEffectiveAppearanceChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onVisibilityChange?(window != nil && !isHiddenOrHasHiddenAncestor)
    }

    override func viewDidHide() {
        super.viewDidHide()
        onVisibilityChange?(false)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onVisibilityChange?(window != nil && !isHiddenOrHasHiddenAncestor)
    }
}

@MainActor
private final class PluginPanelStatusOverlay: NSView {
    var onReload: (() -> Void)?

    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    let reloadButton: NSButton

    override init(frame frameRect: NSRect) {
        reloadButton = NSButton(title: String(localized: "重新载入"), target: nil, action: nil)
        super.init(frame: frameRect)
        wantsLayer = true

        messageLabel.font = Theme.font(.panels, size: 12)
        messageLabel.textColor = Theme.text2
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        reloadButton.bezelStyle = .rounded
        reloadButton.controlSize = .small
        reloadButton.target = self
        reloadButton.action = #selector(reloadClicked(_:))
        reloadButton.setAccessibilityIdentifier("pluginPanel.reload")

        let stack = NSStackView(views: [messageLabel, reloadButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor
    }

    func show(message: String) {
        messageLabel.stringValue = message
        isHidden = false
    }

    func hide() {
        isHidden = true
    }

    @objc private func reloadClicked(_ sender: Any?) {
        onReload?()
    }

    @objc private func applyFonts() {
        messageLabel.font = Theme.font(.panels, size: 12)
    }
}

// MARK: - FSEvents 递归监视器

private final class PluginDirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacView.PluginWebPanel.watcher")
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void

    init(directory: URL, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let resolvedPath = directory.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        queue.sync {
            let paths = [resolvedPath] as CFArray
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )
            let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<PluginDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                let hasNonManifest = numEvents == 0 || paths.isEmpty || paths.contains { path in
                    URL(fileURLWithPath: path).lastPathComponent != "manifest.json"
                }
                guard hasNonManifest else { return }
                watcher.onChange()
            }
            if let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05,
                flags
            ) {
                stream = created
                FSEventStreamSetDispatchQueue(created, queue)
                FSEventStreamStart(created)
            }
        }
    }

    func stop() {
        queue.sync {
            guard let stream else { return }
            self.stream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    deinit {
        stop()
    }
}

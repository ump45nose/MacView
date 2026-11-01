#if DEBUG
import AppKit
import MVFoundation
import MVTestSupport
import os
import QuartzCore

/// S0-F1 画布引擎技术验证的测试窗口：1 万项的砌体布局，缩略图来自 MockImagePipeline。
///
/// “运行场景”按显示链接逐帧驱动快速拖动、惯性滚动和改变窗口尺寸，并统计帧间隔与主线程用时。
/// 启动参数 `-MVCanvasTest YES` 直接打开本窗口，`-MVCanvasTestAutorun YES` 打开后运行场景并退出，
/// `-MVCanvasTestReport <路径>` 把结果写成 JSON。
final class CanvasTestWindowController: NSWindowController, NSWindowDelegate {
    static let launchKey = "MVCanvasTest"
    static let autorunKey = "MVCanvasTestAutorun"
    static let reportKey = "MVCanvasTestReport"
    static let pageCount = 10_000

    private static var current: CanvasTestWindowController?

    static func show(autorun: Bool) {
        let controller = current ?? CanvasTestWindowController()
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.startDisplayLink()
        if autorun {
            NSApp.activate()
            // 等首屏缩略图到齐再开始。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { controller.runScenario(terminateWhenDone: true) }
        }
    }

    private enum Timing: Int, CaseIterable {
        case fast
        case nas

        var title: String {
            switch self {
            case .fast: "快速：400 张/秒，延迟 20 ms"
            case .nas: "NAS 首访：2.5 张/秒"
            }
        }

        var mock: MockTiming {
            var timing = MockTiming()
            if self == .fast {
                timing.readsPerSecond = 400
            }
            return timing
        }
    }

    private let tree: MockTree
    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private let hud = NSTextField(labelWithString: "")
    private let timingPopup = NSPopUpButton()
    private let runButton = NSButton()
    private var timing = Timing.fast
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var scenario: ScenarioRun?
    private var hudTimer: Timer?
    private let logger = Logger(category: "canvas-test")

    private init() {
        let (tree, items) = Self.makeLibrary()
        self.tree = tree
        canvas = CanvasView(items: items, pipeline: MockImagePipeline(environment: MockEnvironment(MockOptions(tree: tree, timing: Timing.fast.mock))))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "画布测试（\(Self.pageCount) 项）"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        // 验收要在 ProMotion 屏幕上进行：放到刷新率最高的屏幕中央。
        if let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        } else {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 数据

    /// 1 万张图，尺寸按序号确定性地取自几种常见比例，含横图、方图和长条。
    private static func makeLibrary() -> (MockTree, [CanvasView.Item]) {
        let shapes = [
            PixelSize(width: 3600, height: 5400), PixelSize(width: 5400, height: 3600), PixelSize(width: 4000, height: 4000),
            PixelSize(width: 3000, height: 4000), PixelSize(width: 4000, height: 3000), PixelSize(width: 1080, height: 1920),
            PixelSize(width: 2400, height: 3600), PixelSize(width: 6000, height: 2000), PixelSize(width: 1200, height: 4800),
        ]
        let pages = (1...pageCount).map { number -> (String, PixelSize) in
            var mixed = UInt64(number) &* 0x9E37_79B9_7F4A_7C15
            mixed = (mixed ^ (mixed >> 31)) &* 0xBF58_476D_1CE4_E5B9
            return (String(format: "%05d.jpg", number), shapes[Int((mixed ^ (mixed >> 29)) % UInt64(shapes.count))])
        }
        let tree = MockTree(nodes: [.directory("瀑布流", pages.map { MockNode.image($0.0, $0.1) })])
        let items = pages.map { name, size in
            CanvasView.Item(location: tree.location("瀑布流/\(name)"), aspectRatio: CGFloat(size.width) / CGFloat(size.height))
        }
        return (tree, items)
    }

    // MARK: - 界面

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        for timing in Timing.allCases {
            timingPopup.addItem(withTitle: timing.title)
        }
        timingPopup.target = self
        timingPopup.action = #selector(timingChanged(_:))
        runButton.title = "运行场景"
        runButton.bezelStyle = .push
        runButton.target = self
        runButton.action = #selector(runScenarioAction(_:))
        let bar = NSStackView(views: [timingPopup, runButton])
        bar.orientation = .horizontal
        bar.spacing = 8

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = canvas
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged(_:)), name: NSView.frameDidChangeNotification, object: clip)

        hud.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        hud.textColor = .white
        hud.drawsBackground = true
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        hud.maximumNumberOfLines = 0

        for view in [bar, scrollView, hud] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hud.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
            hud.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -24),
        ])

        canvas.onUpdate = { [weak self] kind, duration in
            self?.scenario?.recordUpdate(kind, duration)
        }
        content.layoutSubtreeIfNeeded()
        canvas.relayout(width: clip.bounds.width)

        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHUD() }
        }
        updateHUD()
    }

    /// 显示链接跟随创建时窗口所在的屏幕，窗口换屏后要重新创建。
    private func startDisplayLink() {
        link?.invalidate()
        let link = canvas.displayLink(target: self, selector: #selector(step(_:)))
        let fastest = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fastest, maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = nil
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if link != nil {
            startDisplayLink()
        }
    }

    private func updateHUD() {
        let counters = canvas.counters
        var lines = [
            "项 \(Self.pageCount) · 图层 \(counters.activeLayers)（峰值 \(counters.peakLayers)，共创建 \(counters.createdLayers)）",
            "已加载 \(counters.loadedImages) · 请求中 \(counters.inFlight)",
        ]
        if let scenario {
            lines.append("场景：\(scenario.currentPhase.name)")
        }
        hud.stringValue = lines.joined(separator: "\n")
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        canvas.updateVisible()
    }

    @objc private func clipFrameChanged(_ notification: Notification) {
        canvas.relayout(width: scrollView.contentView.bounds.width)
    }

    @objc private func timingChanged(_ sender: NSPopUpButton) {
        guard let timing = Timing(rawValue: sender.indexOfSelectedItem), timing != self.timing else { return }
        self.timing = timing
        canvas.reset(pipeline: MockImagePipeline(environment: MockEnvironment(MockOptions(tree: tree, timing: timing.mock))))
    }

    @objc private func runScenarioAction(_ sender: Any?) {
        runScenario(terminateWhenDone: false)
    }

    func windowWillClose(_ notification: Notification) {
        link?.invalidate()
        hudTimer?.invalidate()
        canvas.cancelAll()
        Self.current = nil
    }

    // MARK: - 场景

    private func runScenario(terminateWhenDone: Bool) {
        guard scenario == nil, let window else { return }
        let clip = scrollView.contentView
        scroll(to: (canvas.frame.height - clip.bounds.height) / 2)
        scenario = ScenarioRun(
            phases: ScenarioRun.standard, originalFrame: window.frame, terminateWhenDone: terminateWhenDone,
            refreshInterval: 1000 / Double(max(window.screen?.maximumFramesPerSecond ?? 60, 1))
        )
        runButton.isEnabled = false
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard let last = lastTimestamp, var run = scenario else { return }
        let interval = now - last
        if run.start == nil {
            run.start = now
        }
        let elapsed = now - (run.start ?? now)
        guard let (index, phaseTime) = run.phase(at: elapsed) else {
            scenario = nil
            finish(run)
            return
        }
        run.currentIndex = index
        run.recordInterval(interval)
        // 先写回：下面的滚动会同步触发图层更新，用时记进 `scenario`。
        scenario = run
        let dt = min(interval, 0.05)
        switch run.phases[index].motion {
        case .pause:
            break
        case let .drag(speed, flipEvery):
            scroll(by: speed * (Int(phaseTime / flipEvery).isMultiple(of: 2) ? 1 : -1) * dt)
        case let .flick(initial, count):
            let each = run.phases[index].duration / Double(count)
            let flick = Int(phaseTime / each)
            let velocity = initial * (flick.isMultiple(of: 2) ? 1 : -1) * pow(0.998, (phaseTime - Double(flick) * each) * 1000)
            scroll(by: velocity * dt)
        case let .resize(minWidth, maxWidth, period):
            let width = (minWidth + maxWidth) / 2 + (maxWidth - minWidth) / 2 * sin(2 * .pi * phaseTime / period)
            resizeWindow(width: width, from: run.originalFrame)
        }
    }

    private func scroll(by delta: CGFloat) {
        scroll(to: scrollView.contentView.bounds.origin.y + delta)
    }

    private func scroll(to y: CGFloat) {
        let clip = scrollView.contentView
        let limit = max(0, canvas.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(y, 0), limit)))
        scrollView.reflectScrolledClipView(clip)
    }

    private func resizeWindow(width: CGFloat, from original: NSRect) {
        guard let window else { return }
        var frame = window.frame
        frame.size.width = width.rounded()
        frame.origin.x = original.midX - frame.width / 2
        window.setFrame(frame, display: true)
    }

    private func finish(_ run: ScenarioRun) {
        window?.setFrame(run.originalFrame, display: true)
        runButton.isEnabled = true
        let counters = canvas.counters
        let summary = CanvasTestSummary(
            screen: window?.screen?.localizedName ?? "",
            maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond ?? 0,
            timing: timing.title,
            items: Self.pageCount,
            peakLayers: counters.peakLayers,
            createdLayers: counters.createdLayers,
            activeLayersAtEnd: counters.activeLayers,
            loadedImages: counters.loadedImages,
            phases: run.results()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(summary)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        logger.info("画布测试结果：\(json, privacy: .public)")
        if let path = UserDefaults.standard.string(forKey: Self.reportKey) {
            do {
                try Data((json + "\n").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                logger.error("写结果失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        updateHUD()
        if run.terminateWhenDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
    }
}

/// 一次场景运行：各阶段的帧间隔与主线程用时。
private struct ScenarioRun {
    enum Motion {
        case pause
        /// 匀速拖动，每隔 `flipEvery` 秒换方向。
        case drag(speed: CGFloat, flipEvery: Double)
        /// 松手后的惯性：初速 `initial`，每毫秒衰减为 0.998 倍，与系统的默认减速度相当；方向交替。
        case flick(initial: CGFloat, count: Int)
        /// 窗口宽度按正弦在两个值之间变化。
        case resize(minWidth: CGFloat, maxWidth: CGFloat, period: Double)
    }

    struct Phase {
        var name: String
        var duration: Double
        var motion: Motion
        var measured = true
    }

    static let standard = [
        Phase(name: "准备", duration: 1, motion: .pause, measured: false),
        Phase(name: "快速拖动", duration: 6, motion: .drag(speed: 6000, flipEvery: 1.5)),
        Phase(name: "惯性滚动", duration: 10.5, motion: .flick(initial: 15000, count: 3)),
        Phase(name: "改变窗口尺寸", duration: 6, motion: .resize(minWidth: 800, maxWidth: 1400, period: 2)),
    ]

    let phases: [Phase]
    let originalFrame: NSRect
    let terminateWhenDone: Bool
    /// 屏幕的最短刷新周期，毫秒。
    let refreshInterval: Double
    var start: CFTimeInterval?
    var currentIndex = 0
    private var intervals: [[Double]]
    private var scrollUpdates: [[Double]]
    private var relayouts: [[Double]]

    init(phases: [Phase], originalFrame: NSRect, terminateWhenDone: Bool, refreshInterval: Double) {
        self.phases = phases
        self.originalFrame = originalFrame
        self.terminateWhenDone = terminateWhenDone
        self.refreshInterval = refreshInterval
        intervals = Array(repeating: [], count: phases.count)
        scrollUpdates = Array(repeating: [], count: phases.count)
        relayouts = Array(repeating: [], count: phases.count)
    }

    var currentPhase: Phase {
        phases[currentIndex]
    }

    func phase(at elapsed: Double) -> (Int, Double)? {
        var remaining = elapsed
        for (index, phase) in phases.enumerated() {
            if remaining < phase.duration { return (index, remaining) }
            remaining -= phase.duration
        }
        return nil
    }

    mutating func recordInterval(_ interval: Double) {
        intervals[currentIndex].append(interval * 1000)
    }

    mutating func recordUpdate(_ kind: CanvasView.UpdateKind, _ duration: Duration) {
        let milliseconds = Double(duration.components.attoseconds) * 1e-15 + Double(duration.components.seconds) * 1000
        switch kind {
        case .scroll: scrollUpdates[currentIndex].append(milliseconds)
        case .relayout: relayouts[currentIndex].append(milliseconds)
        }
    }

    func results() -> [CanvasTestSummary.Phase] {
        phases.indices.filter { phases[$0].measured }.map { index in
            let frames = intervals[index]
            return CanvasTestSummary.Phase(
                name: phases[index].name,
                frames: frames.count,
                intervalP50: percentile(frames, 0.5),
                intervalP99: percentile(frames, 0.99),
                intervalMax: frames.max() ?? 0,
                // 超过 1.5 个刷新周期视为显示链接错过了一帧。
                longIntervals: frames.filter { $0 > refreshInterval * 1.5 }.count,
                scrollUpdates: scrollUpdates[index].count,
                scrollUpdateP99: percentile(scrollUpdates[index], 0.99),
                scrollUpdateMax: scrollUpdates[index].max() ?? 0,
                relayouts: relayouts[index].count,
                relayoutP99: percentile(relayouts[index], 0.99),
                relayoutMax: relayouts[index].max() ?? 0
            )
        }
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
    }
}

/// 场景结果，时间单位为毫秒。
struct CanvasTestSummary: Codable {
    struct Phase: Codable {
        var name: String
        var frames: Int
        var intervalP50: Double
        var intervalP99: Double
        var intervalMax: Double
        var longIntervals: Int
        var scrollUpdates: Int
        var scrollUpdateP99: Double
        var scrollUpdateMax: Double
        var relayouts: Int
        var relayoutP99: Double
        var relayoutMax: Double
    }

    var screen: String
    var maximumFramesPerSecond: Int
    var timing: String
    var items: Int
    var peakLayers: Int
    var createdLayers: Int
    var activeLayersAtEnd: Int
    var loadedImages: Int
    var phases: [Phase]
}

extension AppDelegate {
    @objc func showCanvasTest(_ sender: Any?) {
        CanvasTestWindowController.show(autorun: false)
    }
}
#endif

import AppKit
import MVFoundation
import MVLayout
import MVSettings
import os

/// 上次的窗口：frame、标签分组与顺序、每个标签的书和停靠布局。页码来自书记忆。
struct SessionSnapshot: Codable, Sendable, Equatable {
    struct Frame: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: NSRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }

    struct Tab: Codable, Sendable, Equatable {
        var book: Location?
        var dock: DockLayout?
        var waterfallExtent: Double?
    }

    struct Window: Codable, Sendable, Equatable {
        var frame: Frame
        var selected: Int
        var tabs: [Tab]
    }

    /// 从前到后。
    var windows: [Window] = []
}

/// `session.json`：带版本号，原子写入，变化后去抖 500 ms。
///
/// 文件解析失败时不覆盖它，等用户修好或者关掉错误条再保存。
@MainActor
final class SessionStore {
    static let fileName = "session.json"
    private static let saveDelay: Duration = .milliseconds(500)

    /// 文件有问题或者修好了（nil）。
    var onProblem: ((String?) -> Void)?
    private let document: JSONDocumentStore<SessionSnapshot>?
    private var saveTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private var isBroken = false
    private var lastSaved: SessionSnapshot?
    private let logger = Logger(category: "session")

    init(fileURL: URL) {
        do {
            let document = try JSONDocumentStore(fileURL: fileURL, version: 1, defaultValue: SessionSnapshot())
            self.document = document
            observeTask = Task { [weak self] in
                for await change in document.changes() {
                    self?.documentChanged(change)
                }
            }
        } catch {
            document = nil
            logger.error("无法打开 session.json：\(String(describing: error), privacy: .public)")
        }
    }

    var saved: SessionSnapshot { document?.value() ?? SessionSnapshot() }

    private func documentChanged(_ change: DocumentChange) {
        switch change {
        case .reloaded:
            guard isBroken else { return }
            isBroken = false
            onProblem?(nil)
        case let .fileError(message):
            isBroken = true
            onProblem?(message)
        }
    }

    /// 用户关掉了错误条：不再保留坏文件。
    func resumeSaving() {
        isBroken = false
    }

    /// 去抖后取快照写入；内容没变不写。
    func schedule(_ snapshot: @escaping @MainActor () -> SessionSnapshot?) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let value = snapshot() else { return }
            await self?.write(value)
        }
    }

    /// 关窗和退出前立即写入。
    func flush(_ snapshot: SessionSnapshot) async {
        saveTask?.cancel()
        saveTask = nil
        await write(snapshot)
    }

    private func write(_ snapshot: SessionSnapshot) async {
        guard let document, !isBroken, snapshot != lastSaved else { return }
        do {
            try await document.update { $0 = snapshot }
            lastSaved = snapshot
        } catch {
            logger.error("无法保存 session.json：\(String(describing: error), privacy: .public)")
        }
    }
}

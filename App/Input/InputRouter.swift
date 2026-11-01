import AppKit
import MVCommands
import MVFoundation

/// 声明自己的输入作用域的视图，例如查看器。第一响应者或它的上级视图声明了作用域时按声明处理。
@MainActor
protocol InputScoped: NSView {
    var inputScope: InputScope { get }
}

/// 一个窗口的按键路由：响应链没有处理的按键转成 KeyChord，连同第一响应者决定的作用域交给 BindingResolver。
///
/// 文本框、弹出层和菜单先在 AppKit 响应链中处理按键，只有走到窗口的 `keyDown` 的才到这里。
/// 多键序列等待后续按键时通过 `onPendingChange` 显示提示，超时或解析出结果后清除。
@MainActor
final class InputRouter {
    /// 待定提示的内容：已按下的键，以及可接的下一个键和对应命令的标题。
    struct Pending: Equatable {
        var typed: [KeyChord]
        var next: [(chord: KeyChord, title: String)]

        static func == (lhs: Pending, rhs: Pending) -> Bool {
            lhs.typed == rhs.typed && lhs.next.map(\.chord) == rhs.next.map(\.chord)
        }
    }

    private let catalog: CommandCatalog
    private var resolver: BindingResolver
    private var timeout: Task<Void, Never>?
    /// 解析出命令，连同按键时的作用域。
    var onCommand: ((CommandID, [String: JSONValue]?, InputScope) -> Void)?
    var onPendingChange: ((Pending?) -> Void)?
    private(set) var pending: Pending?

    init(catalog: CommandCatalog) {
        self.catalog = catalog
        resolver = BindingResolver(bindings: catalog.bindings, sequenceTimeout: CommandCatalog.sequenceTimeout)
    }

    /// 处理到达窗口的按键；返回 false 时由调用方交给 AppKit 的默认处理。
    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let chord = KeyMapping.chord(for: event) else { return false }
        let scope = Self.scope(of: window.firstResponder)
        switch resolver.feed(chord, scope: scope, at: .now) {
        case let .command(id, arguments):
            setPending(nil)
            onCommand?(id, arguments, scope)
            return true
        case let .pending(typed):
            setPending(Pending(typed: typed, next: catalog.continuations(of: typed, scope: scope)))
            return true
        case .unmatched:
            setPending(nil)
            return false
        }
    }

    /// 作用域由第一响应者决定：文本输入、列表、声明了作用域的视图（查看器），其余为 global。
    static func scope(of responder: NSResponder?) -> InputScope {
        if let text = responder as? NSTextView {
            return text.isEditable ? .textInput : .global
        }
        var view = responder as? NSView
        while let current = view {
            if current is NSTableView || current is NSCollectionView || current is NSBrowser {
                return .list
            }
            if let scoped = current as? InputScoped {
                return scoped.inputScope
            }
            view = current.superview
        }
        return .global
    }

    private func setPending(_ value: Pending?) {
        timeout?.cancel()
        timeout = nil
        if value != nil {
            // 与 BindingResolver 用同一个超时；之后的按键由解析器自己判定超时。
            timeout = Task { [weak self] in
                try? await Task.sleep(for: CommandCatalog.sequenceTimeout)
                guard !Task.isCancelled else { return }
                self?.setPending(nil)
            }
        }
        guard value != pending else { return }
        pending = value
        onPendingChange?(value)
    }
}

import AppKit
import Foundation
import MVCommands
import MVFoundation
import MVIO
import MVReading
import MVScripting
import MVServices

enum ScriptHostError: LocalizedError, Sendable {
    case windowClosed
    case noWindow
    case noBook
    case invalidArgument(String)
    case invalidLocation(String)
    case unavailable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .windowClosed:
            return String(localized: "窗口已关闭")
        case .noWindow:
            return String(localized: "没有打开的窗口")
        case .noBook:
            return String(localized: "当前没有打开的书")
        case let .invalidArgument(message):
            return message
        case let .invalidLocation(message):
            return message
        case let .unavailable(message):
            return message
        case let .commandFailed(message):
            return message
        }
    }
}

/// 在主线程实现 `MVScripting` 的 `ScriptHost` 协议，方法名与参数/返回 JSON 形状严格按 `ScriptAPI`。
@MainActor
final class AppScriptHost: ScriptHost {
    private static let globalScriptControlCommands: Set<CommandID> = [
        .scriptStopAll,
        .scriptRevealFolder,
        .scriptManage,
    ]

    private weak var app: AppDelegate?
    private let services: CoreServices

    init(app: AppDelegate, services: CoreServices) {
        self.app = app
        self.services = services
    }

    func call(_ method: ScriptAPI.Method, _ args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        switch method {
        case .book:
            return try handleBook(context: context)
        case .page:
            return try handlePage(args: args, context: context)
        case .pages:
            return try handlePages(context: context)
        case .selection:
            return .array(context.selection.map(JSONValue.string))
        case .command:
            return try await handleCommand(args: args, context: context)
        case .goTo:
            return try handleGoTo(args: args, context: context)
        case .open:
            return try await handleOpen(args: args, context: context)
        case .toast:
            return try handleToast(args: args, context: context)
        case .confirm:
            return try await handleConfirm(args: args, context: context)
        case .prompt:
            return try await handlePrompt(args: args, context: context)
        case .storageGet:
            return try handleStorageGet(args: args, context: context)
        case .storageSet:
            return try await handleStorageSet(args: args, context: context)
        case .storageRemove:
            return try await handleStorageRemove(args: args, context: context)
        }
    }

    // MARK: - 窗口定位

    /// 按 `context.session` 定位目标窗口：
    /// - 指定了会话但窗口已关闭时抛出“窗口已关闭”，绝不改投其他窗口；
    /// - 未指定会话（如 `startup`）时使用当前主窗口或活动阅读窗口。
    private func resolveWindow(for context: ScriptCallContext, required: Bool) throws -> ReaderWindowController? {
        guard let app else {
            throw ScriptHostError.unavailable(String(localized: "应用不可用"))
        }
        if let sessionID = context.session {
            guard let controller = app.controller(for: sessionID) else {
                throw ScriptHostError.windowClosed
            }
            return controller
        }
        let controller = app.mainController ?? app.activeReaderController
        if required, controller == nil {
            throw ScriptHostError.noWindow
        }
        return controller
    }

    // MARK: - 状态读取

    private func handleBook(context: ScriptCallContext) throws -> JSONValue {
        guard let controller = try resolveWindow(for: context, required: false),
              let book = controller.session.book else {
            return .null
        }
        return .object([
            "location": .string(ScriptLocationCodec.token(for: book.location)),
            "path": ScriptLocationCodec.path(for: book.location).map(JSONValue.string) ?? .null,
            "title": .string(controller.bookTitleForScript(book.location)),
            "pageCount": .number(Double(book.pages.count)),
            "isVirtual": .bool(controller.session.isVirtualBook),
        ])
    }

    private func handlePage(args: [JSONValue], context: ScriptCallContext) throws -> JSONValue {
        let requestedIndex = try optionalInt(args, at: 0, name: "index")
        guard let controller = try resolveWindow(for: context, required: false),
              let book = controller.session.book else {
            return .null
        }
        let index = requestedIndex ?? controller.session.currentPage
        guard book.pages.indices.contains(index) else {
            return .null
        }
        return pageJSON(index: index, page: book.pages[index])
    }

    private func handlePages(context: ScriptCallContext) throws -> JSONValue {
        guard let controller = try resolveWindow(for: context, required: false),
              let book = controller.session.book else {
            return .array([])
        }
        return .array(book.pages.enumerated().map { pageJSON(index: $0.offset, page: $0.element) })
    }

    private func pageJSON(index: Int, page: Page) -> JSONValue {
        let location = page.id
        return .object([
            "index": .number(Double(index)),
            "location": .string(ScriptLocationCodec.token(for: location)),
            "path": ScriptLocationCodec.path(for: location).map(JSONValue.string) ?? .null,
            "name": .string(page.entry.name),
            "width": page.metadata.map { .number(Double($0.pixelSize.width)) } ?? .null,
            "height": page.metadata.map { .number(Double($0.pixelSize.height)) } ?? .null,
            "isVideo": .bool(page.entry.kind == .video),
            "rating": page.metadata?.rating.map { .number(Double($0)) } ?? .null,
            "tags": page.metadata?.tags.map { .array($0.map(JSONValue.string)) } ?? .null,
        ])
    }

    // MARK: - 导航与命令

    private func handleCommand(args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        let rawID = try requireString(args, at: 0, name: "id")
        guard !rawID.isEmpty else {
            throw ScriptHostError.invalidArgument(String(localized: "命令 ID 不能为空"))
        }
        let commandArgs = try optionalObject(args, at: 1, name: "args")

        guard let app else {
            throw ScriptHostError.unavailable(String(localized: "应用不可用"))
        }
        let commandID = CommandID(rawID)
        let targetSession: SessionID?
        if let sessionID = context.session {
            if app.controller(for: sessionID) != nil {
                targetSession = sessionID
            } else if Self.globalScriptControlCommands.contains(commandID) {
                targetSession = nil
            } else {
                throw ScriptHostError.windowClosed
            }
        } else {
            targetSession = (app.mainController ?? app.activeReaderController)?.session.id
        }

        var selectionLocations: [Location] = []
        selectionLocations.reserveCapacity(context.selection.count)
        for token in context.selection {
            selectionLocations.append(try await ScriptLocationCodec.location(from: token, sources: services.sources))
        }

        let commandContext = CommandContext(session: targetSession, scope: .global, selection: selectionLocations)
        do {
            try await services.commands.perform(commandID, arguments: commandArgs, context: commandContext)
        } catch let error as CommandError {
            switch error {
            case let .unknownCommand(id):
                throw ScriptHostError.commandFailed(String(localized: "未知命令：\(id.rawValue)"))
            case let .disabled(id):
                throw ScriptHostError.commandFailed(String(localized: "命令当前不可用：\(id.rawValue)"))
            }
        }
        return .null
    }

    private func handleGoTo(args: [JSONValue], context: ScriptCallContext) throws -> JSONValue {
        let index = try requireInt(args, at: 0, name: "index")
        guard let controller = try resolveWindow(for: context, required: true) else {
            throw ScriptHostError.noWindow
        }
        guard let book = controller.session.book, !book.pages.isEmpty else {
            throw ScriptHostError.noBook
        }
        controller.session.go(.index(index))
        return .null
    }

    private func handleOpen(args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        let token = try requireString(args, at: 0, name: "location")
        guard let controller = try resolveWindow(for: context, required: true) else {
            throw ScriptHostError.noWindow
        }
        let location = try await ScriptLocationCodec.location(from: token, sources: services.sources)
        await controller.session.open(location, at: nil)
        if Task.isCancelled {
            throw CancellationError()
        }
        if let error = controller.session.loadError {
            throw ScriptHostError.invalidLocation(ErrorText.describe(error))
        }
        return .null
    }

    // MARK: - 界面交互

    private func handleToast(args: [JSONValue], context: ScriptCallContext) throws -> JSONValue {
        let text = try requireString(args, at: 0, name: "text")
        guard let controller = try resolveWindow(for: context, required: false) else {
            return .null
        }
        controller.content.statusBar.showMessage(text)
        return .null
    }

    private func handleConfirm(args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        let text = try requireString(args, at: 0, name: "text")
        guard let controller = try resolveWindow(for: context, required: true),
              let window = controller.window else {
            throw context.session != nil ? ScriptHostError.windowClosed : ScriptHostError.noWindow
        }
        let alert = NSAlert()
        alert.messageText = context.callerName
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "确定"))
        alert.addButton(withTitle: String(localized: "取消"))
        let response = try await presentSheet(alert, on: window)
        return .bool(response == .alertFirstButtonReturn)
    }

    private func handlePrompt(args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        let text = try requireString(args, at: 0, name: "text")
        let defaultValue = try optionalString(args, at: 1, name: "defaultValue")
        guard let controller = try resolveWindow(for: context, required: true),
              let window = controller.window else {
            throw context.session != nil ? ScriptHostError.windowClosed : ScriptHostError.noWindow
        }
        let alert = NSAlert()
        alert.messageText = context.callerName
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "确定"))
        alert.addButton(withTitle: String(localized: "取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = try await presentSheet(alert, on: window)
        if response == .alertFirstButtonReturn {
            return .string(field.stringValue)
        }
        return .null
    }

    private func presentSheet(_ alert: NSAlert, on window: NSWindow) async throws -> NSApplication.ModalResponse {
        if Task.isCancelled {
            throw CancellationError()
        }
        @MainActor
        final class SheetState {
            var finished = false
            var cancelled = false
        }
        let state = SheetState()
        let response: NSApplication.ModalResponse = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    MainActor.assumeIsolated {
                        state.finished = true
                        continuation.resume(returning: response)
                    }
                }
                if state.cancelled && !state.finished {
                    window.endSheet(alert.window, returnCode: .cancel)
                }
            }
        } onCancel: {
            Task { @MainActor in
                state.cancelled = true
                guard !state.finished else { return }
                window.endSheet(alert.window, returnCode: .cancel)
            }
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        return response
    }

    // MARK: - 持久存储

    private func handleStorageGet(args: [JSONValue], context: ScriptCallContext) throws -> JSONValue {
        let key = try requireStorageKey(args)
        guard let storage = services.scriptStorage else {
            throw ScriptHostError.unavailable(String(localized: "脚本存储不可用"))
        }
        return storage.get(context.caller, key)
    }

    private func handleStorageSet(args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        let key = try requireStorageKey(args)
        guard args.count >= 2 else {
            throw ScriptHostError.invalidArgument(String(localized: "storage.set 需要传入值"))
        }
        guard let storage = services.scriptStorage else {
            throw ScriptHostError.unavailable(String(localized: "脚本存储不可用"))
        }
        try await storage.set(context.caller, key, args[1])
        return .null
    }

    private func handleStorageRemove(args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        let key = try requireStorageKey(args)
        guard let storage = services.scriptStorage else {
            throw ScriptHostError.unavailable(String(localized: "脚本存储不可用"))
        }
        try await storage.remove(context.caller, key)
        return .null
    }

    // MARK: - 参数校验

    private func requireStorageKey(_ args: [JSONValue]) throws -> String {
        let key = try requireString(args, at: 0, name: "key")
        guard !key.isEmpty else {
            throw ScriptHostError.invalidArgument(String(localized: "存储键名不能为空"))
        }
        return key
    }

    private func requireString(_ args: [JSONValue], at index: Int, name: String) throws -> String {
        guard args.indices.contains(index) else {
            throw ScriptHostError.invalidArgument(String(localized: "缺少参数 \(name)"))
        }
        guard case let .string(value) = args[index] else {
            throw ScriptHostError.invalidArgument(String(localized: "参数 \(name) 必须是字符串"))
        }
        return value
    }

    private func optionalString(_ args: [JSONValue], at index: Int, name: String) throws -> String? {
        guard args.indices.contains(index) else { return nil }
        switch args[index] {
        case .null: return nil
        case let .string(value): return value
        default:
            throw ScriptHostError.invalidArgument(String(localized: "参数 \(name) 必须是字符串"))
        }
    }

    private func requireInt(_ args: [JSONValue], at index: Int, name: String) throws -> Int {
        guard args.indices.contains(index) else {
            throw ScriptHostError.invalidArgument(String(localized: "缺少参数 \(name)"))
        }
        return try parseInt(args[index], name: name)
    }

    private func optionalInt(_ args: [JSONValue], at index: Int, name: String) throws -> Int? {
        guard args.indices.contains(index) else { return nil }
        if case .null = args[index] { return nil }
        return try parseInt(args[index], name: name)
    }

    private func parseInt(_ value: JSONValue, name: String) throws -> Int {
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            throw ScriptHostError.invalidArgument(String(localized: "参数 \(name) 必须是整数"))
        }
        return Int(number)
    }

    private func optionalObject(_ args: [JSONValue], at index: Int, name: String) throws -> [String: JSONValue]? {
        guard args.indices.contains(index) else { return nil }
        switch args[index] {
        case .null: return nil
        case let .object(dict): return dict
        default:
            throw ScriptHostError.invalidArgument(String(localized: "参数 \(name) 必须是对象"))
        }
    }
}

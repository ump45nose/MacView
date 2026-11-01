// MVCommands：命令登记、按键序列与作用域解析，以及默认命令、绑定与菜单模型。职责与契约见 docs/architecture.md §2、§4。
import Foundation
import MVFoundation

/// 命令标识，例如 `page.next`。JSON 中是一个字符串。
public struct CommandID: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum InputScope: String, Codable, Sendable {
    case global, viewer, list, textInput
}

public struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)
}

/// 一次按键：逻辑键名（如 `Right`、`a`）加修饰键。
public struct KeyChord: Hashable, Codable, Sendable {
    public var key: String
    public var modifiers: KeyModifiers

    public init(_ key: String, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct KeyBinding: Codable, Sendable, Hashable {
    public var sequence: [KeyChord]
    public var command: CommandID
    public var arguments: [String: JSONValue]?
    public var scope: InputScope

    public init(sequence: [KeyChord], command: CommandID, arguments: [String: JSONValue]? = nil, scope: InputScope = .global) {
        self.sequence = sequence
        self.command = command
        self.arguments = arguments
        self.scope = scope
    }
}

public enum ResolveResult: Sendable, Equatable {
    case command(CommandID, [String: JSONValue]?)
    /// 已按下的键是某个多键序列的前缀，等待后续按键。
    case pending([KeyChord])
    case unmatched
}

public struct CommandDescriptor: Sendable {
    public var id: CommandID
    public var title: LocalizedStringResource
    public var category: String
    public var defaultBindings: [KeyBinding]

    public init(id: CommandID, title: LocalizedStringResource, category: String, defaultBindings: [KeyBinding] = []) {
        self.id = id
        self.title = title
        self.category = category
        self.defaultBindings = defaultBindings
    }
}

/// 执行命令时的上下文：所在会话、输入作用域与当前选择。
public struct CommandContext: Sendable {
    public var session: SessionID?
    public var scope: InputScope
    public var selection: [Location]

    public init(session: SessionID? = nil, scope: InputScope, selection: [Location] = []) {
        self.session = session
        self.scope = scope
        self.selection = selection
    }
}

public enum CommandError: Error, Sendable, Equatable {
    case unknownCommand(CommandID)
    case disabled(CommandID)
}

/// 命令登记表。菜单、快捷键、手势、脚本和插件都经 `perform` 执行命令。
@MainActor public final class CommandRegistry {
    private struct Registration {
        var descriptor: CommandDescriptor
        var isEnabled: @MainActor (CommandContext) -> Bool
        var perform: @MainActor (CommandContext, [String: JSONValue]?) async throws -> Void
    }

    private var registrations: [CommandID: Registration] = [:]
    private var order: [CommandID] = []

    public init() {}

    /// 登记命令；同一个标识再次登记时替换处理器，位置不变。
    public func register(
        _ descriptor: CommandDescriptor,
        isEnabled: @escaping @MainActor (CommandContext) -> Bool,
        perform: @escaping @MainActor (CommandContext, [String: JSONValue]?) async throws -> Void
    ) {
        if registrations[descriptor.id] == nil {
            order.append(descriptor.id)
        }
        registrations[descriptor.id] = Registration(descriptor: descriptor, isEnabled: isEnabled, perform: perform)
    }

    /// 菜单项与工具栏按钮用来判断是否可用；没登记的命令不可用。
    public func isEnabled(_ id: CommandID, context: CommandContext) -> Bool {
        registrations[id]?.isEnabled(context) ?? false
    }

    public func perform(_ id: CommandID, arguments: [String: JSONValue]?, context: CommandContext) async throws {
        guard let registration = registrations[id] else { throw CommandError.unknownCommand(id) }
        guard registration.isEnabled(context) else { throw CommandError.disabled(id) }
        try await registration.perform(context, arguments)
    }

    /// 按登记顺序。
    public func descriptors() -> [CommandDescriptor] {
        order.compactMap { registrations[$0]?.descriptor }
    }
}

public indirect enum MenuNode: Codable, Sendable, Hashable {
    case command(CommandID)
    case submenu(titleKey: String, children: [MenuNode])
    case separator
}

public struct MenuModel: Codable, Sendable, Hashable {
    public var roots: [MenuNode]

    public init(roots: [MenuNode]) {
        self.roots = roots
    }
}

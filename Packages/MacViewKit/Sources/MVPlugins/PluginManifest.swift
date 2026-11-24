import Foundation
import MVFoundation
import MVScripting

public enum PluginPermission: String, Sendable, Codable, CaseIterable, Hashable {
    case network
    case commands
}

public enum PluginRuntimeKind: Sendable, Hashable, Codable {
    case javascript(entry: String)
    case process(command: String, arguments: [String])

    private enum CodingKeys: String, CodingKey {
        case js
        case process
    }

    private struct ProcessSpec: Codable {
        var command: String
        var args: [String]?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let js = try container.decodeIfPresent(String.self, forKey: .js)
        let process = try container.decodeIfPresent(ProcessSpec.self, forKey: .process)
        switch (js, process) {
        case let (.some(entry), .none):
            self = .javascript(entry: entry)
        case let (.none, .some(spec)):
            self = .process(command: spec.command, arguments: spec.args ?? [])
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "runtime 必须且只能包含 js 或 process")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .javascript(entry):
            try container.encode(entry, forKey: .js)
        case let .process(command, arguments):
            try container.encode(ProcessSpec(command: command, args: arguments.isEmpty ? nil : arguments), forKey: .process)
        }
    }
}

public struct PluginCommandDeclaration: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public enum PluginFieldType: String, Sendable, Hashable, Codable, CaseIterable {
    case text
    case url
    case password
    case number
}

public struct PluginFieldDeclaration: Sendable, Hashable, Codable {
    public var key: String
    public var label: String
    public var type: PluginFieldType
    public var required: Bool

    public init(key: String, label: String, type: PluginFieldType, required: Bool = false) {
        self.key = key
        self.label = label
        self.type = type
        self.required = required
    }
}

public struct PluginSourceDeclaration: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var fields: [PluginFieldDeclaration]

    public init(id: String, name: String, fields: [PluginFieldDeclaration] = []) {
        self.id = id
        self.name = name
        self.fields = fields
    }

    public var passwordFieldKeys: Set<String> {
        Set(fields.filter { $0.type == .password }.map(\.key))
    }
}

public enum PluginFilterParameterType: String, Sendable, Hashable, Codable, CaseIterable {
    case number
    case bool
    case choice
}

public struct PluginFilterParameter: Sendable, Hashable, Codable {
    public var key: String
    public var label: String
    public var type: PluginFilterParameterType
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var options: [String]?
    public var defaultValue: JSONValue?

    enum CodingKeys: String, CodingKey {
        case key, label, type, min, max, step, options
        case defaultValue = "default"
    }

    public init(
        key: String,
        label: String,
        type: PluginFilterParameterType,
        min: Double? = nil,
        max: Double? = nil,
        step: Double? = nil,
        options: [String]? = nil,
        defaultValue: JSONValue? = nil
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.min = min
        self.max = max
        self.step = step
        self.options = options
        self.defaultValue = defaultValue
    }
}

public struct PluginFilterDeclaration: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var parameters: [PluginFilterParameter]

    public init(id: String, name: String, parameters: [PluginFilterParameter] = []) {
        self.id = id
        self.name = name
        self.parameters = parameters
    }
}

public struct PluginProblem: Sendable, Hashable, Error, LocalizedError {
    public var file: String
    public var line: Int?
    public var column: Int?
    public var message: String

    public init(file: String, line: Int? = nil, column: Int? = nil, message: String) {
        self.file = file
        self.line = line
        self.column = column
        self.message = message
    }

    public var errorDescription: String? {
        if let line, let column {
            return "\(file):\(line):\(column): \(message)"
        }
        if let line {
            return "\(file):\(line): \(message)"
        }
        return "\(file): \(message)"
    }
}

public struct PluginManifest: Sendable, Hashable, Codable {
    public var name: String
    public var version: String
    public var description: String?
    public var runtime: PluginRuntimeKind
    public var permissions: [PluginPermission]
    public var commands: [PluginCommandDeclaration]
    public var events: [ScriptEventName]
    public var sources: [PluginSourceDeclaration]
    public var filters: [PluginFilterDeclaration]

    public init(
        name: String,
        version: String,
        description: String? = nil,
        runtime: PluginRuntimeKind,
        permissions: [PluginPermission] = [],
        commands: [PluginCommandDeclaration] = [],
        events: [ScriptEventName] = [],
        sources: [PluginSourceDeclaration] = [],
        filters: [PluginFilterDeclaration] = []
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.runtime = runtime
        self.permissions = permissions
        self.commands = commands
        self.events = events
        self.sources = sources
        self.filters = filters
    }

    /// 校验文件夹名是否满足 `[a-z0-9][a-z0-9-]*`。
    public static func isValidPluginID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first else { return false }
        let isLowerAlphaNum: (UnicodeScalar) -> Bool = { scalar in
            (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
        }
        guard isLowerAlphaNum(first) else { return false }
        return id.unicodeScalars.allSatisfy { isLowerAlphaNum($0) || $0 == "-" }
    }

    public func sourceDeclaration(for type: String) -> PluginSourceDeclaration? {
        sources.first { $0.id == type }
    }

    public func filterDeclaration(for id: String) -> PluginFilterDeclaration? {
        filters.first { $0.id == id }
    }

    /// 严格解析清单 JSON，并在失败时返回带文件与行列位置的 `PluginProblem`。
    public static func parse(data: Data, file: String = "manifest.json") -> Result<PluginManifest, PluginProblem> {
        let text = String(decoding: data, as: UTF8.self)
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(syntaxProblem(error, text: text, file: file))
        }
        guard let root = rawObject as? [String: Any] else {
            return .failure(PluginProblem(file: file, line: 1, column: 1, message: "清单顶层必须是 JSON 对象"))
        }

        func problem(_ message: String, key: String? = nil, valueToken: String? = nil) -> PluginProblem {
            let pos = locate(key: key, valueToken: valueToken, in: text)
            return PluginProblem(file: file, line: pos.line, column: pos.column, message: message)
        }

        guard let name = root["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let msg = root["name"] == nil ? "缺少必填字段 name" : "name 必须是非空字符串"
            return .failure(problem(msg, key: "name"))
        }
        guard let version = root["version"] as? String, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let msg = root["version"] == nil ? "缺少必填字段 version" : "version 必须是非空字符串"
            return .failure(problem(msg, key: "version"))
        }
        let description: String?
        if let rawDesc = root["description"], !(rawDesc is NSNull) {
            guard let s = rawDesc as? String else {
                return .failure(problem("description 必须是字符串", key: "description"))
            }
            description = s
        } else {
            description = nil
        }

        // runtime
        guard let rawRuntime = root["runtime"] as? [String: Any] else {
            let msg = root["runtime"] == nil ? "缺少必填字段 runtime" : "runtime 必须是对象"
            return .failure(problem(msg, key: "runtime"))
        }
        let hasJS = rawRuntime["js"] != nil && !(rawRuntime["js"] is NSNull)
        let hasProcess = rawRuntime["process"] != nil && !(rawRuntime["process"] is NSNull)
        guard hasJS != hasProcess else {
            return .failure(problem("runtime 必须且只能声明 js 或 process 之一", key: "runtime"))
        }
        let runtime: PluginRuntimeKind
        if hasJS {
            guard let entry = rawRuntime["js"] as? String, !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(problem("runtime.js 必须是非空字符串", key: "js"))
            }
            runtime = .javascript(entry: entry)
        } else {
            guard let proc = rawRuntime["process"] as? [String: Any] else {
                return .failure(problem("runtime.process 必须是对象", key: "process"))
            }
            guard let command = proc["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let msg = proc["command"] == nil ? "缺少必填字段 runtime.process.command" : "runtime.process.command 必须是非空字符串"
                return .failure(problem(msg, key: "command"))
            }
            var arguments: [String] = []
            if let rawArgs = proc["args"], !(rawArgs is NSNull) {
                guard let arr = rawArgs as? [Any] else {
                    return .failure(problem("runtime.process.args 必须是字符串数组", key: "args"))
                }
                for item in arr {
                    guard let s = item as? String else {
                        return .failure(problem("runtime.process.args 的元素必须是字符串", key: "args"))
                    }
                    arguments.append(s)
                }
            }
            runtime = .process(command: command, arguments: arguments)
        }

        // permissions
        var permissions: [PluginPermission] = []
        if let rawPerms = root["permissions"], !(rawPerms is NSNull) {
            guard let arr = rawPerms as? [Any] else {
                return .failure(problem("permissions 必须是字符串数组", key: "permissions"))
            }
            for item in arr {
                guard let s = item as? String, let perm = PluginPermission(rawValue: s) else {
                    let token = item as? String
                    return .failure(problem("未知权限：\(item)", key: "permissions", valueToken: token))
                }
                if !permissions.contains(perm) { permissions.append(perm) }
            }
        }

        // commands
        var commands: [PluginCommandDeclaration] = []
        if let rawCommands = root["commands"], !(rawCommands is NSNull) {
            guard let arr = rawCommands as? [Any] else {
                return .failure(problem("commands 必须是数组", key: "commands"))
            }
            var seenIDs: Set<String> = []
            for item in arr {
                guard let dict = item as? [String: Any] else {
                    return .failure(problem("commands 元素必须是对象", key: "commands"))
                }
                guard let id = dict["id"] as? String, !id.isEmpty else {
                    return .failure(problem("命令缺少非空 id", key: "commands"))
                }
                guard let title = dict["title"] as? String, !title.isEmpty else {
                    return .failure(problem("命令 \(id) 缺少非空 title", key: "commands", valueToken: id))
                }
                guard seenIDs.insert(id).inserted else {
                    return .failure(problem("命令 id 重复：\(id)", key: "commands", valueToken: id))
                }
                commands.append(PluginCommandDeclaration(id: id, title: title))
            }
        }

        // events
        var events: [ScriptEventName] = []
        if let rawEvents = root["events"], !(rawEvents is NSNull) {
            guard let arr = rawEvents as? [Any] else {
                return .failure(problem("events 必须是字符串数组", key: "events"))
            }
            for item in arr {
                guard let s = item as? String, let event = ScriptEventName(rawValue: s) else {
                    return .failure(problem("未知事件：\(item)", key: "events", valueToken: item as? String))
                }
                if !events.contains(event) { events.append(event) }
            }
        }

        // sources
        var sources: [PluginSourceDeclaration] = []
        if let rawSources = root["sources"], !(rawSources is NSNull) {
            guard let arr = rawSources as? [Any] else {
                return .failure(problem("sources 必须是数组", key: "sources"))
            }
            var seenIDs: Set<String> = []
            for item in arr {
                guard let dict = item as? [String: Any] else {
                    return .failure(problem("sources 元素必须是对象", key: "sources"))
                }
                guard let id = dict["id"] as? String, !id.isEmpty else {
                    return .failure(problem("来源声明缺少非空 id", key: "sources"))
                }
                guard let sourceName = dict["name"] as? String, !sourceName.isEmpty else {
                    return .failure(problem("来源 \(id) 缺少非空 name", key: "sources", valueToken: id))
                }
                guard seenIDs.insert(id).inserted else {
                    return .failure(problem("来源 id 重复：\(id)", key: "sources", valueToken: id))
                }
                var fields: [PluginFieldDeclaration] = []
                if let rawFields = dict["fields"], !(rawFields is NSNull) {
                    guard let fieldArr = rawFields as? [Any] else {
                        return .failure(problem("来源 \(id) 的 fields 必须是数组", key: "fields"))
                    }
                    var seenKeys: Set<String> = []
                    for rawField in fieldArr {
                        guard let f = rawField as? [String: Any] else {
                            return .failure(problem("fields 元素必须是对象", key: "fields"))
                        }
                        guard let key = f["key"] as? String, !key.isEmpty else {
                            return .failure(problem("来源字段缺少非空 key", key: "fields"))
                        }
                        guard let label = f["label"] as? String, !label.isEmpty else {
                            return .failure(problem("来源字段 \(key) 缺少非空 label", key: "fields", valueToken: key))
                        }
                        guard let rawType = f["type"] as? String, let fieldType = PluginFieldType(rawValue: rawType) else {
                            return .failure(problem("来源字段 \(key) 的 type 无效", key: "fields", valueToken: f["type"] as? String ?? key))
                        }
                        var required = false
                        if let rawReq = f["required"], !(rawReq is NSNull) {
                            guard let boolVal = asBool(rawReq) else {
                                return .failure(problem("来源字段 \(key) 的 required 必须是布尔值", key: "required", valueToken: key))
                            }
                            required = boolVal
                        }
                        guard seenKeys.insert(key).inserted else {
                            return .failure(problem("来源字段 key 重复：\(key)", key: "fields", valueToken: key))
                        }
                        fields.append(PluginFieldDeclaration(key: key, label: label, type: fieldType, required: required))
                    }
                }
                sources.append(PluginSourceDeclaration(id: id, name: sourceName, fields: fields))
            }
        }

        // filters
        var filters: [PluginFilterDeclaration] = []
        if let rawFilters = root["filters"], !(rawFilters is NSNull) {
            guard let arr = rawFilters as? [Any] else {
                return .failure(problem("filters 必须是数组", key: "filters"))
            }
            if !arr.isEmpty, case .javascript = runtime {
                return .failure(problem("JS 插件不支持声明 filters，只有外部程序插件可以提供滤镜", key: "filters"))
            }
            var seenIDs: Set<String> = []
            for item in arr {
                guard let dict = item as? [String: Any] else {
                    return .failure(problem("filters 元素必须是对象", key: "filters"))
                }
                guard let id = dict["id"] as? String, !id.isEmpty else {
                    return .failure(problem("滤镜声明缺少非空 id", key: "filters"))
                }
                guard let filterName = dict["name"] as? String, !filterName.isEmpty else {
                    return .failure(problem("滤镜 \(id) 缺少非空 name", key: "filters", valueToken: id))
                }
                guard seenIDs.insert(id).inserted else {
                    return .failure(problem("滤镜 id 重复：\(id)", key: "filters", valueToken: id))
                }
                var parameters: [PluginFilterParameter] = []
                if let rawParams = dict["parameters"], !(rawParams is NSNull) {
                    guard let paramArr = rawParams as? [Any] else {
                        return .failure(problem("滤镜 \(id) 的 parameters 必须是数组", key: "parameters"))
                    }
                    var seenKeys: Set<String> = []
                    for rawParam in paramArr {
                        guard let p = rawParam as? [String: Any] else {
                            return .failure(problem("parameters 元素必须是对象", key: "parameters"))
                        }
                        guard let key = p["key"] as? String, !key.isEmpty else {
                            return .failure(problem("滤镜参数缺少非空 key", key: "parameters"))
                        }
                        guard let label = p["label"] as? String, !label.isEmpty else {
                            return .failure(problem("滤镜参数 \(key) 缺少非空 label", key: "parameters", valueToken: key))
                        }
                        guard let rawType = p["type"] as? String, let paramType = PluginFilterParameterType(rawValue: rawType) else {
                            return .failure(problem("滤镜参数 \(key) 的 type 无效", key: "parameters", valueToken: p["type"] as? String ?? key))
                        }
                        guard seenKeys.insert(key).inserted else {
                            return .failure(problem("滤镜参数 key 重复：\(key)", key: "parameters", valueToken: key))
                        }
                        var minVal: Double?
                        var maxVal: Double?
                        var stepVal: Double?
                        var options: [String]?
                        if let rawMin = p["min"], !(rawMin is NSNull) {
                            guard let v = asDouble(rawMin) else { return .failure(problem("滤镜参数 \(key) 的 min 必须是数字", key: "min")) }
                            minVal = v
                        }
                        if let rawMax = p["max"], !(rawMax is NSNull) {
                            guard let v = asDouble(rawMax) else { return .failure(problem("滤镜参数 \(key) 的 max 必须是数字", key: "max")) }
                            maxVal = v
                        }
                        if let rawStep = p["step"], !(rawStep is NSNull) {
                            guard let v = asDouble(rawStep), v > 0 else { return .failure(problem("滤镜参数 \(key) 的 step 必须是正数", key: "step")) }
                            stepVal = v
                        }
                        if let rawOptions = p["options"], !(rawOptions is NSNull) {
                            guard let optArr = rawOptions as? [Any] else {
                                return .failure(problem("滤镜参数 \(key) 的 options 必须是字符串数组", key: "options"))
                            }
                            var strings: [String] = []
                            for opt in optArr {
                                guard let s = opt as? String else {
                                    return .failure(problem("滤镜参数 \(key) 的 options 元素必须是字符串", key: "options"))
                                }
                                strings.append(s)
                            }
                            options = strings
                        }
                        if paramType == .choice && (options == nil || options!.isEmpty) {
                            return .failure(problem("choice 类型滤镜参数 \(key) 必须提供非空 options", key: "options", valueToken: key))
                        }
                        var defaultValue: JSONValue?
                        if let rawDefault = p["default"], !(rawDefault is NSNull) {
                            defaultValue = jsonValue(from: rawDefault)
                        }
                        parameters.append(PluginFilterParameter(
                            key: key, label: label, type: paramType,
                            min: minVal, max: maxVal, step: stepVal,
                            options: options, defaultValue: defaultValue
                        ))
                    }
                }
                filters.append(PluginFilterDeclaration(id: id, name: filterName, parameters: parameters))
            }
        }

        return .success(PluginManifest(
            name: name,
            version: version,
            description: description,
            runtime: runtime,
            permissions: permissions,
            commands: commands,
            events: events,
            sources: sources,
            filters: filters
        ))
    }

    private static func asBool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func asDouble(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        return d.isFinite ? d : nil
    }

    private static func jsonValue(from any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let b = asBool(any) { return .bool(b) }
        if let d = asDouble(any) { return .number(d) }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] { return .array(arr.map(jsonValue(from:))) }
        if let dict = any as? [String: Any] { return .object(dict.mapValues(jsonValue(from:))) }
        return .null
    }

    private static func syntaxProblem(_ error: any Error, text: String, file: String) -> PluginProblem {
        let nsError = error as NSError
        let detail = nsError.userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
        if let regex = try? NSRegularExpression(pattern: #"line (\d+), column (\d+)"#),
           let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
           let lineRange = Range(match.range(at: 1), in: detail), let line = Int(detail[lineRange]),
           let columnRange = Range(match.range(at: 2), in: detail), let column = Int(detail[columnRange]) {
            return PluginProblem(file: file, line: line, column: column, message: detail)
        }
        let offset: String.Index
        if let index = nsError.userInfo["NSJSONSerializationErrorIndex"] as? Int {
            offset = text.index(text.startIndex, offsetBy: min(max(0, index), text.count))
        } else {
            offset = text.startIndex
        }
        let (line, column) = lineColumn(at: offset, in: text)
        return PluginProblem(file: file, line: line, column: column, message: detail)
    }

    private static func locate(key: String?, valueToken: String?, in text: String) -> (line: Int, column: Int) {
        if let valueToken, let range = text.range(of: "\"\(valueToken)\"") {
            return lineColumn(at: range.lowerBound, in: text)
        }
        if let key, let range = text.range(of: "\"\(key)\"") {
            return lineColumn(at: range.lowerBound, in: text)
        }
        return (1, 1)
    }

    private static func lineColumn(at offset: String.Index, in text: String) -> (Int, Int) {
        let prefix = text[..<offset]
        let line = prefix.filter { $0 == "\n" }.count + 1
        let column = prefix.reversed().prefix(while: { $0 != "\n" }).count + 1
        return (line, column)
    }
}

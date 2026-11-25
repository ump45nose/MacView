import Foundation

public struct ExternalCommand: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case application, program, shell }
    public var id: String
    public var name: String
    public var kind: Kind
    public var program: String?
    public var arguments: String
    public var workingDirectory: String?
    public var showOutput: Bool

    public init(id: String, name: String, kind: Kind, program: String? = nil, arguments: String, workingDirectory: String? = nil, showOutput: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.program = program; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.showOutput = showOutput
    }
    private enum CodingKeys: String, CodingKey { case id, name, kind, program, arguments, workingDirectory, showOutput }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(Kind.self, forKey: .kind)
        program = try values.decodeIfPresent(String.self, forKey: .program)
        arguments = try values.decode(String.self, forKey: .arguments)
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
        showOutput = try values.decodeIfPresent(Bool.self, forKey: .showOutput) ?? false
    }
}

public struct ExternalCommandFile: Codable, Sendable, Hashable {
    public var commands: [ExternalCommand]
    public init(commands: [ExternalCommand]) { self.commands = commands }
}

public struct TemplateValues: Sendable {
    public var files: [String]
    public var book: String?
    public var page: Int?
    public init(files: [String], book: String?, page: Int?) { self.files = files; self.book = book; self.page = page }
}

public enum CommandTemplate {
    public static let placeholders = ["{file}", "{files}", "{folder}", "{name}", "{book}", "{page}"]

    public enum TemplateError: Error, LocalizedError, Sendable {
        case unclosedQuote, trailingEscape
        public var errorDescription: String? {
            switch self { case .unclosedQuote: String(localized: "参数模板中的引号没有闭合", bundle: .main); case .trailingEscape: String(localized: "参数模板末尾缺少转义字符", bundle: .main) }
        }
    }

    public static func programArguments(_ template: String, values: TemplateValues) throws -> [String] {
        var words: [String] = []; var word = ""; var quote: Character?; var escaped = false; var started = false
        for char in template {
            if escaped { word.append(char); started = true; escaped = false; continue }
            if char == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let active = quote {
                if char == active { quote = nil } else { word.append(char) }
                started = true
            } else if char == "'" || char == "\"" { quote = char; started = true }
            else if char.isWhitespace {
                if started { words.append(word); word = ""; started = false }
            } else { word.append(char); started = true }
        }
        if escaped { throw TemplateError.trailingEscape }
        if quote != nil { throw TemplateError.unclosedQuote }
        if started { words.append(word) }
        return words.flatMap { word in
            if word == "{files}" { return values.files }
            return [replace(word) { key in rawValue(key, values: values) }]
        }
    }

    public static func shellInvocation(_ template: String, values: TemplateValues) -> ShellInvocation {
        let script = replace(template) { key in
            switch key {
            case "{file}": #""${MV_FILE}""#
            case "{files}": #""$@""#
            case "{folder}": #""${MV_FOLDER}""#
            case "{name}": #""${MV_NAME}""#
            case "{book}": #""${MV_BOOK}""#
            case "{page}": #""${MV_PAGE}""#
            default: key
            }
        }
        return ShellInvocation(script: script, positional: values.files, environment: [
            "MV_FILE": rawValue("{file}", values: values),
            "MV_FOLDER": rawValue("{folder}", values: values),
            "MV_NAME": rawValue("{name}", values: values),
            "MV_BOOK": rawValue("{book}", values: values),
            "MV_PAGE": rawValue("{page}", values: values),
        ])
    }

    private static func rawValue(_ key: String, values: TemplateValues) -> String {
        let file = values.files.first ?? ""
        return switch key {
        case "{file}": file
        case "{files}": values.files.joined(separator: " ")
        case "{folder}": file.isEmpty ? "" : (file as NSString).deletingLastPathComponent
        case "{name}": file.isEmpty ? "" : (file as NSString).lastPathComponent
        case "{book}": values.book ?? ""
        case "{page}": values.page.map(String.init) ?? ""
        default: key
        }
    }
    private static func replace(_ template: String, value: (String) -> String) -> String {
        var result = ""; var index = template.startIndex
        while index < template.endIndex {
            if let key = placeholders.first(where: { template[index...].hasPrefix($0) }) {
                result += value(key); index = template.index(index, offsetBy: key.count)
            } else { result.append(template[index]); template.formIndex(after: &index) }
        }
        return result
    }
}

public struct ShellInvocation: Sendable, Hashable {
    public var script: String
    public var positional: [String]
    public var environment: [String: String]
    public init(script: String, positional: [String], environment: [String: String]) {
        self.script = script; self.positional = positional; self.environment = environment
    }
}

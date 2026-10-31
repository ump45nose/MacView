import Foundation

/// 把结果编码为 JSON，写到文件或标准输出。
enum JSONReport {
    static func write<Value: Encodable>(_ value: Value, to path: String?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let path else {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            return
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

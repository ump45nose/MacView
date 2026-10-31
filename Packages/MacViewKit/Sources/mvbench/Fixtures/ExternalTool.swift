import CryptoKit
import Foundation

/// 调用外部命令：生成 WebP 用 Homebrew 的 webp 工具，核对压缩包用系统的 bsdtar 和 gzip。
enum ExternalTool {
    /// 在 PATH 和 Homebrew 的目录里找命令。
    static func find(_ name: String, install: String) throws -> String {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let path = directories.map({ "\($0)/\(name)" }).first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw FixtureError("找不到 \(name)，请先运行 \(install)")
        }
        return path
    }

    /// 运行到结束，返回标准输出；退出码不为 0 时抛出，并附上标准错误。
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            throw FixtureError("\(name) 退出码 \(process.terminationStatus)：\(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return data
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

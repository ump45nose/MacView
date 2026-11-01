import Foundation
import MVSettings

/// 由真实测试启动并 SIGKILL，不自行结束；目录由测试提供。
enum SettingsWriter {
    static func run() async throws {
        guard let path = CommandLine.arguments.dropFirst(2).first else { throw WriterError.invalidMode }
        let store = try FileSettingsStore(directory: URL(fileURLWithPath: path, isDirectory: true))
        var iteration = 0
        while true {
            iteration += 1
            let next = iteration
            try await store.updateGlobal { global in
                global.maxDecodeLongSide = 8192 + next
                global.defaultBook.fixedScale = Double(next)
            }
        }
    }
}

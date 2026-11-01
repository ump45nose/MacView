import Foundation
import MVCache

enum CacheWriter {
    /// 测试以 cache <workspace-directory> 启动，收到首个 ready 后在随机写入点 SIGKILL。
    static func run() async throws {
        guard let path = CommandLine.arguments.dropFirst(2).first else { throw WriterError.invalidMode }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let index = try CacheIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let cache = try DiskCache(tier: .thumbnails, cacheDirectory: directory, budget: 64 << 20, index: index)
        var sequence = 0
        while true {
            // 每一代使用新键，数据内容与键可独立核验，不靠 writer 的内存快照。
            let key = String(format: "%032x", sequence)
            let byte = UInt8(sequence % 251)
            let data = Data(repeating: byte, count: 16_384 + sequence % 4096)
            try await cache.store(data, for: key)
            if sequence == 7 { FileHandle.standardOutput.write(Data("ready\n".utf8)) }
            sequence += 1
        }
    }
}

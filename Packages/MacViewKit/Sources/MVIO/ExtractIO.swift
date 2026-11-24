import Foundation

/// 解出目录只在本机；阻塞的文件操作与 Swift 协作执行器分离。
package enum ExtractIO {
    package static let queue = DispatchQueue(label: "io.github.ump45nose.MacView.archive.extract")

    package static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }

    package static func remove(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        queue.async { for url in urls { try? FileManager.default.removeItem(at: url) } }
    }

    package static func drain() async { _ = try? await run {} }
}

/// 句柄的所有访问都排在 ExtractIO.queue；close 也在该队列中。
package final class ExtractOutput: @unchecked Sendable {
    private let handle: FileHandle
    private init(handle: FileHandle) { self.handle = handle }

    package static func create(_ url: URL) async throws -> ExtractOutput {
        try await ExtractIO.run {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            return ExtractOutput(handle: try FileHandle(forWritingTo: url))
        }
    }
    package func write(_ data: Data) async throws { try await ExtractIO.run { [handle] in try handle.write(contentsOf: data) } }
    package func synchronize() async throws { try await ExtractIO.run { [handle] in try handle.synchronize() } }
    package func close() { ExtractIO.queue.async { [handle] in try? handle.close() } }
}

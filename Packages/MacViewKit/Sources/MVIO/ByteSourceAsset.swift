import AVFoundation
import Foundation
import MVFoundation
import UniformTypeIdentifiers

/// 把 `ByteSource` 包成 `AVURLAsset`：AVFoundation 经 AVAssetResourceLoader 按范围取数据，读取走 I/O 调度。
/// 网络卷上的视频用它打开，AVFoundation 不在进程内直接读网络卷；本机卷直接用文件 URL。
///
/// 资源加载器只弱引用代理，所以调用方要持有这个对象，直到不再使用 `asset`。
public final class ByteSourceAsset: Sendable {
    public let asset: AVURLAsset
    private let loader: Loader

    /// - Parameter priority: 每次取数据的优先级；播放用 `.visible`，生成封面用 `.near`。
    public init(source: any ByteSource, priority: IOPriority = .visible) {
        loader = Loader(source: source, priority: priority)
        var components = URLComponents()
        components.scheme = "macview-bytes"
        components.host = "source"
        components.path = "/" + source.identity.cacheKey + "/" + source.identity.location.name
        asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }

    private final class Loader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "io.github.ump45nose.MacView.io.asset")
        private let source: any ByteSource
        private let priority: IOPriority
        /// 只在 queue 上访问。
        private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

        init(source: any ByteSource, priority: IOPriority) {
            self.source = source
            self.priority = priority
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
            let size = source.identity.size
            if let information = loadingRequest.contentInformationRequest {
                information.contentType = UTType(filenameExtension: (source.identity.location.name as NSString).pathExtension)?.identifier
                information.contentLength = size
                information.isByteRangeAccessSupported = true
            }
            guard let dataRequest = loadingRequest.dataRequest else {
                loadingRequest.finishLoading()
                return true
            }
            let start = dataRequest.requestedOffset
            let end = dataRequest.requestsAllDataToEndOfResource ? size : min(size, start + Int64(dataRequest.requestedLength))
            let request = UncheckedBox(loadingRequest)
            let key = ObjectIdentifier(loadingRequest)
            let (source, priority) = (source, priority)
            tasks[key] = Task {
                // 分段交给 AVFoundation，播放可以在整段读完之前开始。
                let step: Int64 = 1 << 20
                var offset = start
                do {
                    while offset < end, !Task.isCancelled {
                        let data = try await source.read(offset..<min(end, offset + step), priority: priority, group: nil)
                        guard !data.isEmpty else { break }
                        queue.async { request.value.dataRequest?.respond(with: data) }
                        offset += Int64(data.count)
                    }
                    queue.async {
                        self.tasks[key] = nil
                        if !request.value.isCancelled { request.value.finishLoading() }
                    }
                } catch {
                    queue.async {
                        self.tasks[key] = nil
                        if !request.value.isCancelled { request.value.finishLoading(with: error) }
                    }
                }
            }
            return true
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
            tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
        }
    }
}

/// AVFoundation 的请求对象不是 Sendable；这里只在加载器的队列上使用它。
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

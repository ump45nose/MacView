import Foundation
import MVFoundation
import MVIO
import Synchronization

/// 按 HTTP Range 读取远端文件；若服务器不支持 Range（回 200），则整份存入共享 `ExtractStore` 后切片读取。
public final class HTTPByteSource: ByteSource, Sendable {
    public let identity: ContentIdentity
    public let url: URL
    public let headers: [String: String]
    private let limiter: PriorityPermitQueue
    private let extracts: ExtractStore
    private let session: URLSession
    private let timeout: TimeInterval
    private let fullLease = Mutex<ExtractLease?>(nil)

    init(
        identity: ContentIdentity,
        url: URL,
        headers: [String: String],
        limiter: PriorityPermitQueue,
        extracts: ExtractStore,
        session: URLSession,
        timeout: TimeInterval
    ) {
        self.identity = identity
        self.url = url
        self.headers = headers
        self.limiter = limiter
        self.extracts = extracts
        self.session = session
        self.timeout = timeout
    }

    private var fullCacheKey: String {
        identity.cacheKey + "-http-full"
    }

    public func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        if Task.isCancelled { throw IOError.cancelled }
        let lower = max(0, range.lowerBound)
        let upper = identity.size > 0 ? min(range.upperBound, identity.size) : range.upperBound
        guard lower < upper else { return Data() }

        if let lease = cachedFullLease() {
            return try await readFromLocalFile(lease.url, range: lower..<upper)
        }

        return try await limiter.withPermit(priority: priority) {
            if Task.isCancelled { throw IOError.cancelled }
            if let lease = cachedFullLease() {
                return try await readFromLocalFile(lease.url, range: lower..<upper)
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.httpMethod = "GET"
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.setValue("bytes=\(lower)-\(upper - 1)", forHTTPHeaderField: "Range")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw IOError.cancelled }
                if error.code == .timedOut { throw IOError.timeout }
                throw IOError.underlying(error.localizedDescription)
            } catch is CancellationError {
                throw IOError.cancelled
            } catch {
                if Task.isCancelled { throw IOError.cancelled }
                throw IOError.underlying(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw IOError.underlying(String(localized: "非 HTTP 响应：\(url.absoluteString)", bundle: .main))
            }

            switch http.statusCode {
            case 206:
                let requested = Int(min(upper - lower, Int64(data.count)))
                return data.count == requested ? data : data.prefix(requested)
            case 200:
                // 服务器不认 Range，将整份内容存入共享 ExtractStore 后切片返回。
                let lease = try await storeFullBody(data)
                fullLease.withLock { $0 = lease }
                let total = Int64(data.count)
                let start = min(lower, total)
                let end = min(upper, total)
                guard start < end else { return Data() }
                return data[Int(start)..<Int(end)]
            case 404:
                throw IOError.notFound(identity.location)
            case 416:
                return Data()
            default:
                throw IOError.underlying("HTTP \(http.statusCode)：\(url.absoluteString)")
            }
        }
    }

    private func cachedFullLease() -> ExtractLease? {
        if let held = fullLease.withLock({ $0 }) {
            return held
        }
        if let acquired = extracts.acquire(fullCacheKey) {
            fullLease.withLock { $0 = acquired }
            return acquired
        }
        return nil
    }

    private func storeFullBody(_ data: Data) async throws -> ExtractLease {
        let temporary = extracts.temporaryURL()
        do {
            try await ExtractIO.run {
                try data.write(to: temporary, options: [])
            }
            let ext = (identity.location.name as NSString).pathExtension
            return try await extracts.install(temporary, key: fullCacheKey, size: Int64(data.count), pathExtension: ext)
        } catch {
            ExtractIO.remove([temporary])
            throw error
        }
    }

    private func readFromLocalFile(_ fileURL: URL, range: Range<Int64>) async throws -> Data {
        try await ExtractIO.run {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let length = Int(range.upperBound - range.lowerBound)
            return try handle.read(upToCount: length) ?? Data()
        }
    }
}

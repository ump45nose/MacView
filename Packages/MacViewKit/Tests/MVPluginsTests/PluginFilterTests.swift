import CoreGraphics
import Foundation
import ImageIO
import MVArchive
import MVCache
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import MVScripting
import MVSettings
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import MVPlugins

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func waitUntil(timeout: Duration = .seconds(3), _ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            while !Task.isCancelled {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        group.addTask { try? await Task.sleep(for: timeout); return false }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

/// 生成一张鲜红的彩色 PNG 图片用于测试灰度滤镜。
private func writeRedPNG(width: Int, height: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    ctx.setFillColor(red: 0.9, green: 0.15, blue: 0.1, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let cgImage = try #require(ctx.makeImage())
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, cgImage, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func makeZip(containing fileURL: URL, to destination: URL) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    proc.currentDirectoryURL = fileURL.deletingLastPathComponent()
    proc.arguments = ["-q", destination.path, fileURL.lastPathComponent]
    try proc.run()
    proc.waitUntilExit()
    #expect(proc.terminationStatus == 0)
}

/// 读取渲染图中心像素的 sRGB (r, g, b) 值，用于验证是否已转为灰度。
private func centerPixelRGB(of image: CGImage) throws -> (r: UInt8, g: UInt8, b: UInt8) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var pixel = [UInt8](repeating: 0, count: 4)
    let ctx = try #require(CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let cx = image.width / 2
    let cy = image.height / 2
    let cropped = try #require(image.cropping(to: CGRect(x: cx, y: cy, width: 1, height: 1)))
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (pixel[0], pixel[1], pixel[2])
}

/// 包装真实执行器以统计调用次数与验证未开滤镜路径不触发插件。
private final class CountingExecutor: PluginFilterExecuting, Sendable {
    let inner: any PluginFilterExecuting
    let calls = Mutex<Int>(0)
    let versionOverride = Mutex<String?>(nil)

    init(inner: any PluginFilterExecuting) {
        self.inner = inner
    }

    func version(of plugin: String) -> String? {
        if let v = versionOverride.withLock({ $0 }) { return v }
        return inner.version(of: plugin)
    }

    func apply(_ request: PluginFilterRequest, input: URL, output: URL) async throws {
        calls.withLock { $0 += 1 }
        try await inner.apply(request, input: input, output: output)
    }
}

@Test func effectPluginRoundTripsAndPreservesUnknownPlugins() throws {
    let pluginEffect = PluginFilterEffect(
        plugin: "unknown-upscaler",
        filter: "esrgan",
        parameters: ["scale": .string("4"), "denoise": .number(0.5), "fast": .bool(true)],
        enabled: true
    )
    let disabledEffect = PluginFilterEffect(plugin: "grayscale", filter: "grayscale", parameters: [:], enabled: false)
    let chain = EffectChain(effects: [
        .colorAdjust(ColorAdjust(brightness: 0.2)),
        .plugin(pluginEffect),
        .plugin(disabledEffect),
    ])
    #expect(!chain.isIdentity)
    #expect(EffectChain(effects: [.plugin(disabledEffect)]).isIdentity)

    let data = try JSONEncoder().encode(chain)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains(#""type":"plugin""#))
    #expect(text.contains(#""plugin":"unknown-upscaler""#))

    let decoded = try JSONDecoder().decode(EffectChain.self, from: data)
    #expect(decoded == chain)
}

@Test func grayscalePluginFiltersLocalAndZipImagesWithCacheAndInvalidation() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/MVPluginsFilterTests/gray-\(UUID().uuidString)")
    let pluginsDir = root.appendingPathComponent("Plugins")
    let cacheDir = root.appendingPathComponent("Cache")
    let mediaDir = root.appendingPathComponent("Media")
    try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.copyItem(
        at: repoRootURL().appendingPathComponent("Examples/Plugins/grayscale"),
        to: pluginsDir.appendingPathComponent("grayscale")
    )

    let redFile = mediaDir.appendingPathComponent("red.png")
    try writeRedPNG(width: 120, height: 80, to: redFile)
    let zipFile = mediaDir.appendingPathComponent("pack.zip")
    try makeZip(containing: redFile, to: zipFile)

    let settings = try JSONDocumentStore(fileURL: root.appendingPathComponent("plugins.json"), version: 1, defaultValue: PluginSettingsFile())
    let secrets = try PluginSecrets(fileURL: root.appendingPathComponent("plugin-secrets.json"))
    let log = ScriptLog()
    try await settings.update { $0.plugins["grayscale"] = PluginState(enabled: true, grantedPermissions: []) }

    let library = PluginLibrary(directory: pluginsDir)
    #expect(await waitUntil { library.plugins().contains { $0.id == "grayscale" } })
    let host = PluginHost(
        library: library, settings: settings, secrets: secrets, log: log,
        configuration: PluginHostConfiguration(
            pythonLibraryDirectory: repoRootURL().appendingPathComponent("PluginSupport/python"),
            supportDirectory: root
        )
    )
    defer { host.shutdown() }

    let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
    defer { scheduler.shutdown() }
    let registry = FileSourceRegistry(scheduler: scheduler)
    let extracts = try ExtractStore(directory: cacheDir.appendingPathComponent("extract"))
    registry.register(ArchiveProvider(fileSystem: registry.fileSystem, extracts: extracts) { _ in registry.fileSystem })

    let cacheIndex = try CacheIndex(databaseURL: cacheDir.appendingPathComponent("index.sqlite"))
    let caches = PipelineCaches(
        raw: MemoryCache(budget: 32 << 20),
        decoded: MemoryCache(budget: 32 << 20),
        thumbnails: try DiskCache(tier: .thumbnails, cacheDirectory: cacheDir, budget: 32 << 20, index: cacheIndex),
        browse: try DiskCache(tier: .browse, cacheDirectory: cacheDir, budget: 32 << 20, index: cacheIndex),
        metadata: MetadataIndex(index: cacheIndex),
        thumbnailMemory: MemoryCache(budget: 16 << 20),
        preload: MemoryCache(budget: 32 << 20)
    )
    let runner = PluginFilterRunner(host: host)
    let counting = CountingExecutor(inner: runner)
    let pipeline = FileImagePipeline(
        sources: registry,
        decoder: ImageDecoder(),
        caches: caches,
        configuration: PipelineConfiguration(browseBounds: PixelSize(width: 1024, height: 1024), pluginFilterExecutor: counting)
    )
    defer { Task { await pipeline.shutdown() } }

    let localLoc = try await registry.location(for: redFile)
    let localEntry = try await registry.provider(for: localLoc).entry(at: localLoc)
    let target = DisplayTarget(pixelSize: PixelSize(width: 120, height: 80))

    // C1.21：未开插件滤镜的路径不调用插件执行器
    for try await _ in pipeline.image(for: localEntry.identity, target: target, allowOriginal: true, priority: .visible) {}
    #expect(counting.calls.withLock { $0 } == 0)

    // C1.18：本地图经灰度示例插件处理，尺寸不变且像素为灰度
    let filterReq = PluginFilterRequest(plugin: "grayscale", filter: "grayscale", parameters: [:])
    let gray1 = try await pipeline.filteredImage(for: localEntry.identity, filters: [filterReq], target: target, priority: .visible)
    #expect(gray1.image.width == 120 && gray1.image.height == 80)
    let px1 = try centerPixelRGB(of: gray1.image)
    #expect(abs(Int(px1.r) - Int(px1.g)) <= 2 && abs(Int(px1.g) - Int(px1.b)) <= 2)
    #expect(counting.calls.withLock { $0 } == 1)

    // 第二次请求命中内存缓存，不调插件
    let gray2 = try await pipeline.filteredImage(for: localEntry.identity, filters: [filterReq], target: target, priority: .visible)
    #expect(gray2.image.width == 120 && gray2.image.height == 80)
    #expect(counting.calls.withLock { $0 } == 1)

    // 清空内存缓存后仍命中 browse 磁盘缓存，不调插件
    caches.decoded.trim(toFraction: 0)
    caches.preload.trim(toFraction: 0)
    let gray3 = try await pipeline.filteredImage(for: localEntry.identity, filters: [filterReq], target: target, priority: .visible)
    #expect(gray3.image.width == 120 && gray3.image.height == 80)
    #expect(counting.calls.withLock { $0 } == 1)

    // C1.19：参数变化不命中旧缓存
    let changedParamReq = PluginFilterRequest(plugin: "grayscale", filter: "grayscale", parameters: ["mode": .string("alt")])
    _ = try await pipeline.filteredImage(for: localEntry.identity, filters: [changedParamReq], target: target, priority: .visible)
    #expect(counting.calls.withLock { $0 } == 2)

    // C1.19：插件版本变化不命中旧缓存
    counting.versionOverride.withLock { $0 = "2.0" }
    _ = try await pipeline.filteredImage(for: localEntry.identity, filters: [filterReq], target: target, priority: .visible)
    #expect(counting.calls.withLock { $0 } == 3)
    counting.versionOverride.withLock { $0 = nil }

    // C1.18：zip 内页同样可经灰度插件处理
    let zipLoc = try await registry.location(for: zipFile)
    let innerLoc = zipLoc.appendingLayer(["red.png"])
    let innerEntry = try await registry.provider(for: innerLoc).entry(at: innerLoc)
    let zipGray = try await pipeline.filteredImage(for: innerEntry.identity, filters: [filterReq], target: target, priority: .visible)
    #expect(zipGray.image.width == 120 && zipGray.image.height == 80)
    let pxZip = try centerPixelRGB(of: zipGray.image)
    #expect(abs(Int(pxZip.r) - Int(pxZip.g)) <= 2 && abs(Int(pxZip.g) - Int(pxZip.b)) <= 2)
    #expect(counting.calls.withLock { $0 } == 4)

    // C1.20b：插件停用时 filteredImage 抛错，重新启用后恢复
    try await settings.update { $0.plugins["grayscale"]?.enabled = false }
    do {
        _ = try await pipeline.filteredImage(for: localEntry.identity, filters: [filterReq], target: target, priority: .visible)
        Issue.record("插件停用时 filteredImage 应抛错")
    } catch {
        // 预期抛错
    }
    try await settings.update { $0.plugins["grayscale"]?.enabled = true }
    let restored = try await pipeline.filteredImage(for: localEntry.identity, filters: [filterReq], target: target, priority: .visible)
    #expect(restored.image.width == 120 && restored.image.height == 80)
}

@Test func filterRunnerSerializesPerPluginAndDropsCancelledQueuedRequests() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/MVPluginsFilterTests/serial-\(UUID().uuidString)")
    let pluginsDir = root.appendingPathComponent("Plugins")
    let pluginDir = pluginsDir.appendingPathComponent("slow-filter")
    let markerDir = root.appendingPathComponent("markers")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 插件记录并发数与每次被调用的 tag
    try """
    {
      "name": "Slow Filter",
      "version": "1.0",
      "runtime": { "process": { "command": "/usr/bin/python3", "args": ["main.py"] } },
      "filters": [{ "id": "slow", "name": "Slow" }]
    }
    """.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try """
    import os, shutil, time, threading
    from macview_plugin import Plugin

    p = Plugin()
    lock = threading.Lock()
    active = 0
    peak = 0
    invoked = []
    marker_dir = r"\(markerDir.path)"

    @p.filter("slow")
    def slow(inp, outp, params):
        global active, peak
        tag = params.get("tag", "")
        with lock:
            active += 1
            peak = max(peak, active)
            invoked.append(tag)
            with open(os.path.join(marker_dir, "state.txt"), "w") as f:
                f.write("{}:{}".format(peak, ",".join(invoked)))
        release_path = os.path.join(marker_dir, "release.txt")
        while not os.path.exists(release_path):
            time.sleep(0.01)
        shutil.copyfile(inp, outp)
        with lock:
            active -= 1

    p.run()
    """.write(to: pluginDir.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)

    let settings = try JSONDocumentStore(fileURL: root.appendingPathComponent("plugins.json"), version: 1, defaultValue: PluginSettingsFile())
    let secrets = try PluginSecrets(fileURL: root.appendingPathComponent("plugin-secrets.json"))
    let log = ScriptLog()
    try await settings.update { $0.plugins["slow-filter"] = PluginState(enabled: true, grantedPermissions: []) }
    let library = PluginLibrary(directory: pluginsDir)
    #expect(await waitUntil(timeout: .seconds(10)) { library.plugins().contains { $0.id == "slow-filter" } })
    let host = PluginHost(
        library: library, settings: settings, secrets: secrets, log: log,
        configuration: PluginHostConfiguration(
            pythonLibraryDirectory: repoRootURL().appendingPathComponent("PluginSupport/python"),
            supportDirectory: root
        )
    )
    defer { host.shutdown() }

    let runner = PluginFilterRunner(host: host)
    let input = root.appendingPathComponent("in.bin")
    try Data("hello".utf8).write(to: input)
    let out1 = root.appendingPathComponent("out1.bin")
    let out2 = root.appendingPathComponent("out2.bin")
    let out3 = root.appendingPathComponent("out3.bin")
    let releaseFile = markerDir.appendingPathComponent("release.txt")

    let t1 = Task {
        try await runner.apply(PluginFilterRequest(plugin: "slow-filter", filter: "slow", parameters: ["tag": .string("first")]), input: input, output: out1)
    }
    // 等第一个请求进入插件执行（CI 冷启动 Python 可能稍慢，给足等待时限）
    #expect(await waitUntil(timeout: .seconds(15)) { FileManager.default.fileExists(atPath: markerDir.appendingPathComponent("state.txt").path) })

    let t2 = Task {
        try await runner.apply(PluginFilterRequest(plugin: "slow-filter", filter: "slow", parameters: ["tag": .string("cancelled")]), input: input, output: out2)
    }
    let t3 = Task {
        try await runner.apply(PluginFilterRequest(plugin: "slow-filter", filter: "slow", parameters: ["tag": .string("third")]), input: input, output: out3)
    }
    try await Task.sleep(for: .milliseconds(50))
    t2.cancel()
    do {
        try await t2.value
        Issue.record("被取消的排队请求应抛 CancellationError")
    } catch is CancellationError {
        // 预期取消并在放行前就已出队
    }

    try Data("go".utf8).write(to: releaseFile)
    try await t1.value
    try await t3.value

    let stateText = try String(contentsOf: markerDir.appendingPathComponent("state.txt"), encoding: .utf8)
    #expect(stateText == "1:first,third")
}

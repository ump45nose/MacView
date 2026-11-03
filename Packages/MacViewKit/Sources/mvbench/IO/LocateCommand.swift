import ArgumentParser
import Foundation
import MVFoundation
import MVIO

/// `mvbench io locate`：检查路径与 Location 的互转。挂载换名或卸载后，用记下的 Location 再解析一次。
struct LocateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "locate",
        abstract: "把路径换成 Location，再解析回当前挂载中的路径；--location 只做反向解析。"
    )

    @Argument(help: "要换算的路径。")
    var paths: [String] = []

    @Option(help: "Location 的 JSON，解析成当前挂载中的路径。")
    var location: [String] = []

    struct Result: Encodable {
        var path: String?
        var location: Location?
        var resolvedPath: String?
        /// 卷未挂载时，“连接”按钮使用的 URL。
        var mountURL: String?
        var error: String?
    }

    func run() async throws {
        let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: Bundle.main.executableURL)))
        var results: [Result] = []
        for path in paths {
            var result = Result(path: path)
            do {
                let location = try await registry.location(for: URL(filePath: path, directoryHint: .inferFromPath))
                result.location = location
                try await resolve(location, registry, into: &result)
            } catch {
                result.error = "\(error)"
            }
            results.append(result)
        }
        for json in location {
            let location = try JSONDecoder().decode(Location.self, from: Data(json.utf8))
            var result = Result(location: location)
            try await resolve(location, registry, into: &result)
            results.append(result)
        }
        registry.scheduler.shutdown()
        try JSONReport.write(results, to: nil)
    }

    private func resolve(_ location: Location, _ registry: FileSourceRegistry, into result: inout Result) async throws {
        do {
            result.resolvedPath = try await registry.provider(for: location).fileLease(for: location).url.path
        } catch IOError.volumeUnavailable(let root) {
            result.error = "volumeUnavailable"
            result.mountURL = root.mountURL?.absoluteString
        }
    }
}

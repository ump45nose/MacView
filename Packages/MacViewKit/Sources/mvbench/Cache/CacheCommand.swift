import ArgumentParser

struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cache", abstract: "测量缓存性能。")
    func run() async throws {}
}

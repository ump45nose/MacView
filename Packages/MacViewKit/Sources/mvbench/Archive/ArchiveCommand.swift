import ArgumentParser

struct ArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive", abstract: "测量压缩包性能。")
    func run() async throws {}
}

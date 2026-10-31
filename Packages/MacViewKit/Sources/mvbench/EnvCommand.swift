import ArgumentParser

struct EnvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "采集机型、系统、网络接口和卷的挂载信息。"
    )

    @Option(name: .customLong("path"), help: "要检查挂载信息的路径，可重复。")
    var paths: [String] = []

    @Option(help: "检查访问该主机时使用的网络接口。")
    var host: String?

    @Option(name: .shortAndLong, help: "JSON 输出文件；省略时输出到标准输出。")
    var output: String?

    func run() throws {
        let environment = BenchEnvironment.collect(paths: paths, host: host)
        try JSONReport.write(environment, to: output)
    }
}

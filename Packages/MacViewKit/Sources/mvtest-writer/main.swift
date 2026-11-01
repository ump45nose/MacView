@main
struct MVTestWriter {
    static func main() async throws {
        guard let mode = CommandLine.arguments.dropFirst().first else {
            throw WriterError.invalidMode
        }
        switch mode {
        case "cache": try await CacheWriter.run()
        case "settings": try await SettingsWriter.run()
        default: throw WriterError.invalidMode
        }
    }
}

enum WriterError: Error {
    case invalidMode
}

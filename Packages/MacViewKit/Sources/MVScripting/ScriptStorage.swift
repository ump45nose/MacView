import Foundation
import MVFoundation
import MVSettings

public final class ScriptStorage: Sendable {
    private let store: JSONDocumentStore<[String: [String: JSONValue]]>

    public init(fileURL: URL) throws {
        store = try JSONDocumentStore(fileURL: fileURL, version: 1, defaultValue: [:])
    }

    public func get(_ script: String, _ key: String) -> JSONValue {
        store.value()[script]?[key] ?? .null
    }

    public func set(_ script: String, _ key: String, _ value: JSONValue) async throws {
        try await store.update { $0[script, default: [:]][key] = value }
    }

    public func remove(_ script: String, _ key: String) async throws {
        try await store.update { values in
            values[script]?.removeValue(forKey: key)
            if values[script]?.isEmpty == true { values.removeValue(forKey: script) }
        }
    }

    public func changes() -> AsyncStream<DocumentChange> {
        store.changes()
    }
}

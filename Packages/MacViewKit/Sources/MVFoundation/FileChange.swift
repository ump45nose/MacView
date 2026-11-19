public enum FileChange: Sendable, Hashable {
    case added(Entry)
    case removed(Location)
    case moved(from: Location, to: Entry)
    case rewritten(Entry, previous: ContentIdentity, metadata: ImageMetadata)
}

public enum ConflictPolicy: String, Sendable, Codable { case appendNumber, skip }
public enum TransferMode: String, Sendable, Codable { case move, copy }

import Foundation
import MVFoundation

public struct Relocation: Sendable, Hashable {
    public var source: Location
    public var target: Location
    public init(source: Location, target: Location) { self.source = source; self.target = target }
}
public indirect enum FileOperation: Sendable, Hashable {
    case delete([Location])
    case deletePermanently([Location])
    case rename(Location, to: String)
    case transfer([Location], into: Location, mode: TransferMode, conflict: ConflictPolicy)
    case relocate([Relocation])
    case makeDirectory(in: Location, name: String)
    case removeEmptyDirectory(Location)
    case sequence([FileOperation])
}
public enum FileOpsError: Error, Sendable, Equatable {
    case readOnly
    case invalidName(String)
    case recycleUnavailable(String)
    case verificationFailed
    case intoItself
}
public struct FileFailure: Sendable {
    public var location: Location
    public var error: any Error
    public init(location: Location, error: any Error) { self.location = location; self.error = error }
}
public struct FileProgress: Sendable, Hashable {
    public var completedItems: Int
    public var totalItems: Int
    public var completedBytes: Int64
    public var totalBytes: Int64
    public init(completedItems: Int = 0, totalItems: Int = 0, completedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.completedItems = completedItems; self.totalItems = totalItems
        self.completedBytes = completedBytes; self.totalBytes = totalBytes
    }
}
public struct FileOperationResult: Sendable {
    public var changes: [FileChange]
    public var inverse: FileOperation?
    public var skipped: [Location]
    public var failures: [FileFailure]
    public init(changes: [FileChange] = [], inverse: FileOperation? = nil, skipped: [Location] = [], failures: [FileFailure] = []) {
        self.changes = changes; self.inverse = inverse; self.skipped = skipped; self.failures = failures
    }
}
public struct RecycleBin: Sendable, Hashable {
    public var location: Location
    public var batchCount: Int
    public init(location: Location, batchCount: Int) { self.location = location; self.batchCount = batchCount }
}
public struct ResumeReport: Sendable, Hashable {
    public var completed: Int
    public var pending: Int
    public var failed: Int
    public init(completed: Int = 0, pending: Int = 0, failed: Int = 0) { self.completed = completed; self.pending = pending; self.failed = failed }
}

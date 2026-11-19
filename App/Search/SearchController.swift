import Foundation
import MVCache
import MVFoundation
import MVServices

/// 书架搜索控制器：持有当前 `SearchQuery`，回车或筛选变更时查询，Esc 清空退出。
@MainActor
final class SearchController {
    private weak var services: CoreServices?
    private var queryTask: Task<Void, Never>?
    private var generation = 0

    private(set) var isSearching = false
    private(set) var isLoading = false
    private(set) var queryText = ""
    private(set) var currentQuery: SearchQuery?
    private(set) var lastResult: SearchResult?
    private(set) var lastError: String?
    private(set) var minimumRating: Int?
    private(set) var selectedTags: [String] = []
    private(set) var selectedKinds: Set<SearchKind> = []

    var resultCount: Int { lastResult?.hits.count ?? 0 }
    var currentTerms: [String] { currentQuery?.terms ?? [] }
    var scopeProvider: (() -> Location?)?
    var onStateChange: (() -> Void)?

    deinit { queryTask?.cancel() }

    func attach(_ services: CoreServices?) { self.services = services }

    static func parseTerms(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private var hasCriteria: Bool {
        !Self.parseTerms(queryText).isEmpty || minimumRating != nil || !selectedTags.isEmpty || !selectedKinds.isEmpty
    }

    func submit(text: String) {
        queryText = text
        if hasCriteria { runQuery() } else if isSearching { cancelSearch() }
    }

    func clearText() {
        queryText = ""
        if !hasCriteria { if isSearching { cancelSearch() } } else if isSearching { runQuery() }
    }

    func updateFilters(minimumRating: Int?, tags: [String], kinds: Set<SearchKind>) {
        self.minimumRating = minimumRating; self.selectedTags = tags; self.selectedKinds = kinds
        if hasCriteria { runQuery() } else if isSearching { cancelSearch() }
    }

    func cancelSearch() {
        queryTask?.cancel(); queryTask = nil; generation += 1
        let changed = isSearching || isLoading || !queryText.isEmpty || currentQuery != nil || lastResult != nil || lastError != nil
            || minimumRating != nil || !selectedTags.isEmpty || !selectedKinds.isEmpty
        isSearching = false; isLoading = false; queryText = ""
        minimumRating = nil; selectedTags = []; selectedKinds = []
        currentQuery = nil; lastResult = nil; lastError = nil
        if changed { onStateChange?() }
    }

    func rerunIfActive() {
        guard isSearching else { return }
        runQuery(preservingScope: currentQuery?.scope)
    }

    func tagSuggestions(prefix: String = "", limit: Int = 50) async -> [String] {
        guard let catalog = services?.search else { return [] }
        return (try? await catalog.tagSuggestions(prefix: prefix, limit: limit)) ?? []
    }

    private func runQuery(preservingScope: Location? = nil) {
        queryTask?.cancel(); queryTask = nil; generation += 1
        let token = generation
        guard let scope = preservingScope ?? scopeProvider?() else {
            isSearching = true; isLoading = false; currentQuery = nil; lastError = nil
            lastResult = SearchResult(hits: [], truncated: false, indexedCount: 0)
            onStateChange?(); return
        }
        let query = SearchQuery(terms: Self.parseTerms(queryText), scope: scope, minimumRating: minimumRating, tags: selectedTags, kinds: selectedKinds)
        currentQuery = query; isSearching = true; lastError = nil
        guard let catalog = services?.search else {
            isLoading = false; lastResult = SearchResult(hits: [], truncated: false, indexedCount: 0)
            onStateChange?(); return
        }
        isLoading = true; onStateChange?()
        queryTask = Task { [weak self] in
            do {
                let result = try await catalog.query(query)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.isLoading = false; self.lastResult = result; self.lastError = nil
                self.onStateChange?()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self, self.generation == token else { return }
                self.isLoading = false; self.lastError = ErrorText.describe(error)
                self.onStateChange?()
            }
        }
    }
}

import Foundation

public typealias NoteID = Int64
public typealias VersionID = Int64

/// A note without its text: everything the sidebar needs.
public struct NoteSummary: Equatable, Hashable, Sendable {
    public var id: NoteID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var wordCount: Int
    public var versionCount: Int
    public var deletedAt: Date?
}

public struct Note: Equatable, Sendable {
    public var id: NoteID
    public var text: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var wordCount: Int
    public var versionCount: Int
    public var deletedAt: Date?

    public var summary: NoteSummary {
        NoteSummary(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
                    wordCount: wordCount, versionCount: versionCount, deletedAt: deletedAt)
    }
}

public struct VersionSummary: Equatable, Hashable, Sendable {
    public var id: VersionID
    public var noteID: NoteID
    public var createdAt: Date
    public var wordCount: Int
    /// "user", or "agent:<name>" for edits made by an agent.
    public var source: String

    public var agentName: String? {
        source.hasPrefix("agent:") ? String(source.dropFirst("agent:".count)) : nil
    }
}

/// Keyset cursor for paging notes ordered by most recently edited.
public struct NoteCursor: Equatable, Sendable {
    public var updatedAt: Date
    public var id: NoteID

    public init(updatedAt: Date, id: NoteID) {
        self.updatedAt = updatedAt
        self.id = id
    }

    public init(after summary: NoteSummary) {
        self.init(updatedAt: summary.updatedAt, id: summary.id)
    }
}

public struct SearchHit: Equatable, Sendable {
    public var note: NoteSummary
    public var matchCount: Int
    /// One line of context around the first match.
    public var snippet: String
    /// UTF-16 ranges of matches inside `snippet`.
    public var snippetMatches: [NSRange]
    /// Counting stopped at `matchCount`; there may be more ("10,000+").
    public var isCountCapped = false
}

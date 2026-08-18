import Foundation

/// A NIP-01 subscription filter, limited to the fields the swarm uses.
public struct NostrFilter: Sendable, Equatable {
    public var kinds: [Int]?
    public var authors: [String]?
    public var since: Int64?
    public var limit: Int?
    /// Tag filters by single-letter name: "x" becomes "#x" on the wire.
    public var tags: [String: [String]]

    public init(kinds: [Int]? = nil, authors: [String]? = nil, since: Int64? = nil,
                limit: Int? = nil, tags: [String: [String]] = [:]) {
        self.kinds = kinds
        self.authors = authors
        self.since = since
        self.limit = limit
        self.tags = tags
    }

    func jsonObject() -> [String: Any] {
        var object = [String: Any]()
        if let kinds { object["kinds"] = kinds }
        if let authors { object["authors"] = authors }
        if let since { object["since"] = since }
        if let limit { object["limit"] = limit }
        for (name, values) in tags { object["#\(name)"] = values }
        return object
    }

    public func matches(_ event: NostrEvent) -> Bool {
        if let kinds, !kinds.contains(event.kind) { return false }
        if let authors, !authors.contains(event.pubkey) { return false }
        if let since, event.createdAt < since { return false }
        for (name, wanted) in tags {
            let present = event.tags.filter { $0.count >= 2 && $0[0] == name }.map { $0[1] }
            if !wanted.contains(where: present.contains) { return false }
        }
        return true
    }
}

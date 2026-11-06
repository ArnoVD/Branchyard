import Foundation

/// Which branches the commit graph leaves out, or the only ones it shows.
public struct GraphFilter: Sendable, Equatable, Codable {
    /// Full ref names hidden from the graph: refs/heads/x, refs/remotes/origin/x.
    public var hiddenRefs: Set<String> = []
    /// Remotes whose branches are all hidden.
    public var hiddenRemotes: Set<String> = []
    /// When not empty, the graph shows only these refs (plus HEAD), and ignores the hidden ones.
    public var soloRefs: Set<String> = []

    public init(hiddenRefs: Set<String> = [], hiddenRemotes: Set<String> = [], soloRefs: Set<String> = []) {
        self.hiddenRefs = hiddenRefs
        self.hiddenRemotes = hiddenRemotes
        self.soloRefs = soloRefs
    }

    public var isEmpty: Bool { hiddenRefs.isEmpty && hiddenRemotes.isEmpty && soloRefs.isEmpty }
    public var isSolo: Bool { !soloRefs.isEmpty }

    /// True when the ref is left out of the graph (its label too).
    public func hides(_ fullRef: String) -> Bool {
        if isSolo { return !soloRefs.contains(fullRef) }
        if hiddenRefs.contains(fullRef) { return true }
        return hiddenRemotes.contains { fullRef.hasPrefix("refs/remotes/\($0)/") }
    }

    /// Hidden by name, not because its whole remote is hidden.
    public func hidesIndividually(_ fullRef: String) -> Bool { hiddenRefs.contains(fullRef) }

    /// The revisions `git log` walks.
    var revisionArgs: [String] {
        if isSolo { return ["--ignore-missing"] + soloRefs.sorted() + ["HEAD"] }
        // `--exclude` patterns apply to the `--all` after them; `*` also matches "/".
        let excludes = hiddenRefs.sorted().map { "--exclude=" + Self.escapeGlob($0) }
            + hiddenRemotes.sorted().map { "--exclude=refs/remotes/" + Self.escapeGlob($0) + "/*" }
        // A remote's HEAD (origin/HEAD) is an alias that `--all` would still walk; it always points
        // at one of the remote's branches, so leaving it out never hides anything that's shown.
        let aliases = excludes.isEmpty ? [] : ["--exclude=refs/remotes/*/HEAD"]
        return excludes + aliases + ["--all"]
    }

    static func escapeGlob(_ text: String) -> String {
        var out = ""
        for c in text {
            if "*?[]\\".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

extension CommitRef {
    /// refs/heads/main, refs/remotes/origin/main, refs/tags/v1, or HEAD.
    public var fullName: String {
        switch kind {
        case .local: return "refs/heads/" + name
        case .remote: return "refs/remotes/" + name
        case .tag: return "refs/tags/" + name
        case .detachedHead: return "HEAD"
        }
    }
}

extension Commit {
    /// The same commit without the labels the filter hides. HEAD's branch always keeps its label.
    func filteringRefs(_ filter: GraphFilter) -> Commit {
        let kept = refs.filter { ref in
            ref.isHead || ref.kind == .tag || ref.kind == .detachedHead || !filter.hides(ref.fullName)
        }
        guard kept.count != refs.count else { return self }
        return Commit(sha: sha, parents: parents, author: author, email: email,
                      date: date, subject: subject, refs: kept)
    }
}

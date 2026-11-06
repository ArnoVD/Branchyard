import Foundation

public enum ChangeKind: String, Sendable, Hashable {
    case modified, added, deleted, renamed, copied, typeChanged, untracked, conflicted

    init(code: Character) {
        switch code {
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        case "?": self = .untracked
        default: self = .modified
        }
    }

    /// One-letter badge shown next to the file name.
    public var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }
}

public enum ChangeArea: String, Sendable, Hashable {
    case staged, unstaged, conflicted
}

public struct FileChange: Identifiable, Hashable, Sendable {
    public let path: String
    public let originalPath: String?
    public let kind: ChangeKind
    public let area: ChangeArea
    /// For conflicts: git's two-letter code, e.g. "UU" (both modified), "UD" (deleted by them).
    public let conflictCode: String?

    public var id: String { "\(area.rawValue):\(path)" }
    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }

    public var conflictDescription: String? {
        switch conflictCode {
        case "UU": return "both modified"
        case "AA": return "both added"
        case "DD": return "both deleted"
        case "AU": return "added by us"
        case "UA": return "added by them"
        case "DU": return "deleted by us"
        case "UD": return "deleted by them"
        default: return nil
        }
    }
}

public struct RepoStatus: Sendable, Equatable {
    public var branch: String?          // nil when HEAD is detached
    public var headOID: String?         // nil before the first commit
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var staged: [FileChange] = []
    public var unstaged: [FileChange] = []
    public var conflicted: [FileChange] = []

    public init() {}

    public var allChanges: [FileChange] { conflicted + unstaged + staged }
    public var isClean: Bool { allChanges.isEmpty }
}

public struct Branch: Identifiable, Hashable, Sendable {
    public let refName: String          // refs/heads/main, refs/remotes/origin/main
    public let name: String             // main, origin/main
    public let isRemote: Bool
    public let isCurrent: Bool
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let upstreamGone: Bool
    public let shortSHA: String
    public let relativeDate: String

    public var id: String { refName }

    /// "origin" for refs/remotes/origin/feature/x.
    public var remoteName: String? {
        guard isRemote else { return nil }
        return refName.dropFirst("refs/remotes/".count).split(separator: "/").first.map(String.init)
    }

    /// "feature/x" for origin/feature/x; same as `name` for local branches.
    public var nameWithoutRemote: String {
        guard let remote = remoteName else { return name }
        return String(name.dropFirst(remote.count + 1))
    }
}

public struct Stash: Identifiable, Hashable, Sendable {
    public let ref: String              // stash@{0}
    public let message: String
    public var id: String { ref }
}

public enum OperationState: String, Sendable {
    case none, merging, rebasing, cherryPicking, reverting

    public var label: String {
        switch self {
        case .none: return ""
        case .merging: return "Merge in progress"
        case .rebasing: return "Rebase in progress"
        case .cherryPicking: return "Cherry-pick in progress"
        case .reverting: return "Revert in progress"
        }
    }
}

public struct DiffLine: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case fileHeader, hunk, added, removed, context, meta }
    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?

    public init(id: Int, kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct GitTag: Identifiable, Hashable, Sendable {
    public let name: String             // v1.2.0
    public let sha: String              // the commit it points at (peeled for annotated tags)
    public var id: String { name }
}

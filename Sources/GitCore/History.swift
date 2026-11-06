import Foundation

// MARK: - Models

public struct CommitRef: Hashable, Sendable {
    public enum Kind: Sendable, Hashable { case local, remote, tag, detachedHead }
    public let kind: Kind
    /// Short name: "main", "origin/main", "v1.0".
    public let name: String
    /// True for the branch HEAD points at.
    public let isHead: Bool

    public init(kind: Kind, name: String, isHead: Bool = false) {
        self.kind = kind
        self.name = name
        self.isHead = isHead
    }

    /// "main" for both main and origin/main, so a local and its remote can share one label.
    public var branchName: String {
        guard kind == .remote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

public struct Commit: Identifiable, Hashable, Sendable {
    public let sha: String
    public let parents: [String]
    public let author: String
    public let email: String
    public let date: Date
    public let subject: String
    public let refs: [CommitRef]

    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    /// Pseudo-commit for uncommitted work, drawn on top of HEAD.
    public static let wipSHA = "WIP"
    public var isWIP: Bool { sha == Commit.wipSHA }

    public init(sha: String, parents: [String], author: String, email: String,
                date: Date, subject: String, refs: [CommitRef]) {
        self.sha = sha
        self.parents = parents
        self.author = author
        self.email = email
        self.date = date
        self.subject = subject
        self.refs = refs
    }

    public static func wip(on head: String?) -> Commit {
        Commit(sha: wipSHA, parents: head.map { [$0] } ?? [], author: "", email: "",
               date: Date(), subject: "// WIP", refs: [])
    }

    /// "Ada Lovelace" → "AL"
    public var initials: String {
        let words = author.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        let letters = words.count >= 2 ? [words.first!, words.last!] : Array(words.prefix(1))
        let result = letters.compactMap { $0.first.map { String($0) } }.joined().uppercased()
        return result.isEmpty ? "?" : String(result.prefix(2))
    }
}

public struct CommitFile: Identifiable, Hashable, Sendable {
    public let path: String
    public let originalPath: String?
    public let kind: ChangeKind
    public var id: String { path }
    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }
}

public struct CommitDetail: Sendable, Equatable {
    public let commit: Commit
    public let body: String          // full message
    public let files: [CommitFile]
}

// MARK: - Graph layout

/// One line piece in a row. Upper pieces run from the row's top edge to its middle,
/// lower pieces from the middle to the bottom edge. Lanes are columns, left to right.
public struct GraphSegment: Hashable, Sendable {
    public let fromLane: Int
    public let toLane: Int
    public let upper: Bool
    public let color: Int
}

public struct GraphRow: Identifiable, Sendable {
    public let commit: Commit
    public let lane: Int
    public let color: Int
    public let segments: [GraphSegment]
    /// Number of lanes this row touches (for sizing the graph column).
    public let width: Int
    public var id: String { commit.sha }
}

public enum GraphLayout {
    /// Assigns each commit a lane and the lines that connect it to its parents.
    /// `commits` must be children-before-parents (git log --date-order / --topo-order).
    public static func rows(for commits: [Commit]) -> [GraphRow] {
        // lanes[i] = the commit sha that lane i is heading down to; nil = free.
        var lanes: [String?] = []
        var laneColor: [Int] = []
        var nextColor = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeLane() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            laneColor.append(0)
            return lanes.count - 1
        }
        func newColor() -> Int { defer { nextColor += 1 }; return nextColor }

        for commit in commits {
            let before = lanes
            let matching = before.indices.filter { before[$0] == commit.sha }

            let lane: Int
            if let first = matching.first {
                lane = first
            } else {
                lane = freeLane()
                laneColor[lane] = newColor()
            }
            let color = laneColor[lane]
            var segments: [GraphSegment] = []

            // Upper half: every lane coming in from above; ones heading to this commit bend into it.
            for (i, target) in before.enumerated() where target != nil {
                let to = target == commit.sha ? lane : i
                segments.append(GraphSegment(fromLane: i, toLane: to, upper: true, color: laneColor[i]))
            }

            // Lanes that ended in this commit are free now (except the commit's own lane).
            for i in matching { lanes[i] = nil }

            // Parents: first parent continues this lane, others join an existing lane or open one.
            var fromNode = Set<Int>()
            for (n, parent) in commit.parents.enumerated() {
                if n == 0 {
                    lanes[lane] = parent
                    fromNode.insert(lane)
                } else if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    fromNode.insert(existing)
                } else {
                    let l = freeLane()
                    lanes[l] = parent
                    laneColor[l] = newColor()
                    fromNode.insert(l)
                }
            }

            // Lower half: lanes passing straight down, plus lines from the node to its parents.
            for (i, target) in lanes.enumerated() where target != nil {
                // A lane that came in from above keeps going, even when a parent line joins it here.
                let passesThrough = i != lane && i < before.count && before[i] == target
                if passesThrough || !fromNode.contains(i) {
                    segments.append(GraphSegment(fromLane: i, toLane: i, upper: false, color: laneColor[i]))
                }
                if fromNode.contains(i) {
                    segments.append(GraphSegment(fromLane: lane, toLane: i, upper: false,
                                                 color: i == lane ? color : laneColor[i]))
                }
            }

            while let last = lanes.last, last == nil {
                lanes.removeLast()
                laneColor.removeLast()
            }

            let width = max(before.count, lanes.count, lane + 1)
            rows.append(GraphRow(commit: commit, lane: lane, color: color, segments: segments, width: width))
        }
        return rows
    }
}

// MARK: - Parsing

extension Parsers {
    static let logFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%D%x1e"

    static func log(_ raw: String) -> [Commit] {
        raw.split(separator: "\u{1e}").compactMap { record in
            let f = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, !f[0].isEmpty else { return nil }
            return Commit(
                sha: f[0],
                parents: f[1].split(separator: " ").map(String.init),
                author: f[2],
                email: f[3],
                date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                subject: f[5],
                refs: refs(f[6])
            )
        }
    }

    /// `%D` with --decorate=full: "HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1"
    public static func refs(_ raw: String) -> [CommitRef] {
        guard !raw.isEmpty else { return [] }
        var result: [CommitRef] = []
        for part in raw.components(separatedBy: ", ") {
            var name = part
            var isHead = false
            if name.hasPrefix("HEAD -> ") {
                name = String(name.dropFirst("HEAD -> ".count))
                isHead = true
            }
            if name == "HEAD" {
                result.append(CommitRef(kind: .detachedHead, name: "HEAD", isHead: true))
            } else if name.hasPrefix("tag: ") {
                result.append(CommitRef(kind: .tag, name: String(name.dropFirst("tag: refs/tags/".count))))
            } else if name.hasPrefix("refs/heads/") {
                result.append(CommitRef(kind: .local, name: String(name.dropFirst("refs/heads/".count)), isHead: isHead))
            } else if name.hasPrefix("refs/remotes/") {
                let short = String(name.dropFirst("refs/remotes/".count))
                if short.hasSuffix("/HEAD") { continue }
                result.append(CommitRef(kind: .remote, name: short))
            }
        }
        return result
    }

    /// `git diff --name-status -z`: "M\0path\0R100\0old\0new\0"
    static func nameStatus(_ raw: String) -> [CommitFile] {
        var tokens = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if tokens.last == "" { tokens.removeLast() }
        var files: [CommitFile] = []
        var i = 0
        while i < tokens.count {
            let status = tokens[i]
            guard let code = status.first else { i += 1; continue }
            if code == "R" || code == "C", i + 2 < tokens.count {
                files.append(CommitFile(path: tokens[i + 2], originalPath: tokens[i + 1], kind: ChangeKind(code: code)))
                i += 3
            } else if i + 1 < tokens.count {
                files.append(CommitFile(path: tokens[i + 1], originalPath: nil, kind: ChangeKind(code: code)))
                i += 2
            } else {
                break
            }
        }
        return files
    }
}

// MARK: - Repository

extension Repository {
    /// Newest-first history of all branches, remotes and tags.
    public func log(limit: Int = 1500) async throws -> [Commit] {
        let r = try await git.run(["-c", "log.showSignature=false", "log", "--all", "--date-order",
                                   "--decorate=full", "-n", String(limit),
                                   "--format=\(Parsers.logFormat)"], allowFailure: true)
        // A repo without commits fails here; that's just an empty history.
        guard r.succeeded else { return [] }
        return Parsers.log(r.stdout)
    }

    public func commitDetail(_ commit: Commit) async throws -> CommitDetail {
        async let body = git.run(["show", "-s", "--format=%B", commit.sha])
        let base = ["-c", "core.quotepath=off"]
        let files: GitResult
        if let parent = commit.parents.first {
            files = try await git.run(base + ["diff", "--name-status", "-M", "-z", parent, commit.sha])
        } else {
            files = try await git.run(base + ["diff-tree", "--root", "--no-commit-id", "-r", "--name-status", "-M", "-z", commit.sha])
        }
        return CommitDetail(
            commit: commit,
            body: try await body.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            files: Parsers.nameStatus(files.stdout)
        )
    }

    /// Diff of one file in a commit, against its first parent.
    public func diff(of file: CommitFile, in commit: Commit) async throws -> [DiffLine] {
        let paths = ["--", file.path] + (file.originalPath.map { [$0] } ?? [])
        let base = ["-c", "core.quotepath=off"]
        let result: GitResult
        if let parent = commit.parents.first {
            result = try await git.run(base + ["diff", "--no-color", "--no-ext-diff", Repository.fullContext, "-M", parent, commit.sha] + paths)
        } else {
            result = try await git.run(base + ["show", "--no-color", "--no-ext-diff", Repository.fullContext, "--format=", commit.sha] + paths)
        }
        return Parsers.diff(result.stdout)
    }
}

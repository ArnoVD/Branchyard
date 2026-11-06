import Foundation

/// One commit that changed a file, with the file's path in that commit (it follows renames).
public struct FileRevision: Identifiable, Hashable, Sendable {
    public let commit: Commit
    public let file: CommitFile
    public var id: String { commit.sha }
}

/// Who last changed each line of a file.
public struct Blame: Sendable, Equatable {
    public struct Line: Identifiable, Hashable, Sendable {
        /// 1-based line number in the blamed version.
        public let number: Int
        public let sha: String
        public let text: String
        public var id: Int { number }
    }

    public struct Origin: Hashable, Sendable {
        public let sha: String
        public let author: String
        public let email: String
        public let date: Date
        public let summary: String
        /// The line isn't committed yet (all-zero SHA).
        public var isUncommitted: Bool { sha.allSatisfy { $0 == "0" } }
        public var shortSHA: String { String(sha.prefix(7)) }
    }

    public let lines: [Line]
    public let origins: [String: Origin]

    public init(lines: [Line], origins: [String: Origin]) {
        self.lines = lines
        self.origins = origins
    }
}

extension Parsers {
    /// `git log --name-status --format=%x1e<fields>`: each record is the commit's fields on
    /// one line, then a blank line and "M\tpath" / "R100\told\tnew" lines.
    static func fileHistory(_ raw: String, path: String) -> [FileRevision] {
        var result: [FileRevision] = []
        var currentPath = path
        for record in raw.split(separator: "\u{1e}") {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let header = lines.first else { continue }
            let f = header.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, !f[0].isEmpty else { continue }
            let commit = Commit(sha: f[0], parents: f[1].split(separator: " ").map(String.init),
                                author: f[2], email: f[3],
                                date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                                subject: f[5], refs: refs(f[6]))
            var file = CommitFile(path: currentPath, originalPath: nil, kind: .modified)
            if let status = lines.dropFirst().first {
                let cols = status.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if let code = cols.first?.first {
                    if (code == "R" || code == "C"), cols.count >= 3 {
                        file = CommitFile(path: cols[2], originalPath: cols[1], kind: ChangeKind(code: code))
                    } else if cols.count >= 2 {
                        file = CommitFile(path: cols[1], originalPath: nil, kind: ChangeKind(code: code))
                    }
                }
            }
            // Older commits know the file by its name before the rename.
            currentPath = file.originalPath ?? file.path
            result.append(FileRevision(commit: commit, file: file))
        }
        return result
    }

    /// `git blame --porcelain`.
    static func blame(_ raw: String) -> Blame {
        var lines: [Blame.Line] = []
        var origins: [String: Blame.Origin] = [:]
        var fields: [String: [String: String]] = [:]
        var sha = ""
        var number = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\t") {
                lines.append(Blame.Line(number: number, sha: sha, text: String(line.dropFirst())))
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let key = parts.first.map(String.init) else { continue }
            if key.count == 40, key.allSatisfy(\.isHexDigit) {
                // "<sha> <original line> <final line> [<group size>]"
                sha = key
                let numbers = parts.count > 1 ? parts[1].split(separator: " ") : []
                number = numbers.count > 1 ? Int(numbers[1]) ?? number + 1 : number + 1
            } else {
                fields[sha, default: [:]][key] = parts.count > 1 ? String(parts[1]) : ""
            }
        }
        for (sha, f) in fields {
            var email = f["author-mail"] ?? ""
            if email.hasPrefix("<"), email.hasSuffix(">") { email = String(email.dropFirst().dropLast()) }
            origins[sha] = Blame.Origin(sha: sha, author: f["author"] ?? "", email: email,
                                        date: Date(timeIntervalSince1970: TimeInterval(f["author-time"] ?? "") ?? 0),
                                        summary: f["summary"] ?? "")
        }
        return Blame(lines: lines, origins: origins)
    }
}

extension Repository {
    /// Newest-first commits that changed `path`, following renames.
    public func fileHistory(_ path: String, limit: Int = 500) async throws -> [FileRevision] {
        let format = "%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%D"
        let r = try await git.run(["-c", "core.quotepath=off", "-c", "log.showSignature=false",
                                   "log", "--follow", "-M", "--name-status", "--decorate=full",
                                   "-n", String(limit), "--format=\(format)", "--", path], allowFailure: true)
        guard r.succeeded else { return [] }
        return Parsers.fileHistory(r.stdout, path: path)
    }

    /// Line-by-line authorship of `path`: of the working copy when `revision` is nil
    /// (uncommitted lines get an all-zero SHA), else of the file in that commit.
    public func blame(_ path: String, at revision: String? = nil) async throws -> Blame {
        let r = try await git.run(["blame", "--porcelain"] + (revision.map { [$0] } ?? []) + ["--", path])
        return Parsers.blame(r.stdout)
    }
}

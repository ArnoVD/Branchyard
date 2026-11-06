import Foundation

public enum Parsers {

    // MARK: status

    /// Parses `git status --porcelain=v2 --branch -z --untracked-files=all`.
    public static func status(_ raw: String) -> RepoStatus {
        var status = RepoStatus()
        let tokens = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0

        func add(xy: Substring, path: String, original: String?) {
            let chars = Array(xy)
            guard chars.count == 2 else { return }
            if chars[0] != "." {
                status.staged.append(FileChange(path: path, originalPath: original,
                                                kind: ChangeKind(code: chars[0]), area: .staged, conflictCode: nil))
            }
            if chars[1] != "." {
                status.unstaged.append(FileChange(path: path, originalPath: nil,
                                                  kind: ChangeKind(code: chars[1]), area: .unstaged, conflictCode: nil))
            }
        }

        while i < tokens.count {
            let token = tokens[i]
            i += 1

            if token.hasPrefix("# ") {
                let parts = token.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": status.headOID = parts[1] == "(initial)" ? nil : parts[1]
                case "branch.head": status.branch = parts[1] == "(detached)" ? nil : parts[1]
                case "branch.upstream": status.upstream = parts[1]
                case "branch.ab":
                    let ab = parts[1].split(separator: " ")
                    if ab.count == 2 {
                        status.ahead = Int(ab[0].dropFirst()) ?? 0
                        status.behind = Int(ab[1].dropFirst()) ?? 0
                    }
                default: break
                }
            } else if token.hasPrefix("1 ") {
                // 1 XY sub mH mI mW hH hI <path>
                let f = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard f.count == 9 else { continue }
                add(xy: f[1], path: String(f[8]), original: nil)
            } else if token.hasPrefix("2 ") {
                // 2 XY sub mH mI mW hH hI Xscore <path> NUL <origPath>
                let f = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let original = i < tokens.count ? tokens[i] : nil
                i += 1
                guard f.count == 10 else { continue }
                add(xy: f[1], path: String(f[9]), original: original)
            } else if token.hasPrefix("u ") {
                // u XY sub m1 m2 m3 mW h1 h2 h3 <path>
                let f = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard f.count == 11 else { continue }
                status.conflicted.append(FileChange(path: String(f[10]), originalPath: nil, kind: .conflicted,
                                                    area: .conflicted, conflictCode: String(f[1])))
            } else if token.hasPrefix("? ") {
                status.unstaged.append(FileChange(path: String(token.dropFirst(2)), originalPath: nil,
                                                  kind: .untracked, area: .unstaged, conflictCode: nil))
            }
        }

        status.staged.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        status.unstaged.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        status.conflicted.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return status
    }

    // MARK: branches

    /// Format string passed to `git for-each-ref`; fields are NUL-separated.
    public static let branchFormat = [
        "%(refname)", "%(refname:short)", "%(upstream:short)", "%(upstream:track,nobracket)",
        "%(HEAD)", "%(objectname:short)", "%(committerdate:relative)",
    ].joined(separator: "%00")

    public static func branches(_ raw: String) -> [Branch] {
        raw.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7 else { return nil }
            let refName = f[0]
            if refName.hasPrefix("refs/remotes/") && refName.hasSuffix("/HEAD") { return nil }
            let track = f[3]
            return Branch(
                refName: refName,
                name: f[1],
                isRemote: refName.hasPrefix("refs/remotes/"),
                isCurrent: f[4] == "*",
                upstream: f[2].isEmpty ? nil : f[2],
                ahead: number(after: "ahead ", in: track),
                behind: number(after: "behind ", in: track),
                upstreamGone: track == "gone",
                shortSHA: f[5],
                relativeDate: f[6]
            )
        }
    }

    private static func number(after prefix: String, in text: String) -> Int {
        guard let range = text.range(of: prefix) else { return 0 }
        return Int(text[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    // MARK: stashes

    /// Parses `git stash list --format=%gd%x00%s`.
    public static func stashes(_ raw: String) -> [Stash] {
        raw.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 2 else { return nil }
            return Stash(ref: f[0], message: f[1])
        }
    }

    // MARK: diff

    public static func diff(_ raw: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var oldNo = 0
        var newNo = 0
        var inHunk = false

        for (index, sub) in raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(sub)
            if text.hasPrefix("diff --git") || (!inHunk && (text.hasPrefix("--- ") || text.hasPrefix("+++ "))) {
                inHunk = false
                lines.append(DiffLine(id: index, kind: .fileHeader, text: text, oldNumber: nil, newNumber: nil))
            } else if text.hasPrefix("@@") {
                inHunk = true
                (oldNo, newNo) = hunkStart(text)
                lines.append(DiffLine(id: index, kind: .hunk, text: text, oldNumber: nil, newNumber: nil))
            } else if inHunk && text.hasPrefix("+") {
                lines.append(DiffLine(id: index, kind: .added, text: text, oldNumber: nil, newNumber: newNo))
                newNo += 1
            } else if inHunk && text.hasPrefix("-") {
                lines.append(DiffLine(id: index, kind: .removed, text: text, oldNumber: oldNo, newNumber: nil))
                oldNo += 1
            } else if inHunk && text.hasPrefix(" ") {
                lines.append(DiffLine(id: index, kind: .context, text: text, oldNumber: oldNo, newNumber: newNo))
                oldNo += 1
                newNo += 1
            } else if text.isEmpty {
                continue
            } else {
                // "\ No newline at end of file", "index …", "Binary files … differ", mode changes
                lines.append(DiffLine(id: index, kind: .meta, text: text, oldNumber: nil, newNumber: nil))
            }
        }
        return lines
    }

    /// "@@ -12,5 +12,7 @@ func x()" → (12, 12)
    private static func hunkStart(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ part: Substring?) -> Int {
            guard let part else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start(parts.count > 1 ? parts[1] : nil), start(parts.count > 2 ? parts[2] : nil))
    }
}

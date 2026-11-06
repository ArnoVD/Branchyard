import Foundation

/// The difference between two commits (or a commit and the working copy).
public struct Comparison: Sendable, Equatable {
    public let files: [CommitFile]
    /// Commits the target has that the base doesn't, newest first.
    public let ahead: [Commit]
    /// Commits the base has that the target doesn't, newest first.
    public let behind: [Commit]

    public init(files: [CommitFile], ahead: [Commit], behind: [Commit]) {
        self.files = files
        self.ahead = ahead
        self.behind = behind
    }
}

extension Repository {
    /// Compares `base` with `target` (any revisions; nil `target` is the working copy, including
    /// untracked files that aren't ignored). With `sinceMergeBase` only what `target` changed since it split off from
    /// `base` counts, like a pull request; otherwise every difference between the two.
    public func compare(_ base: String, _ target: String?, sinceMergeBase: Bool = false,
                        commitLimit: Int = 500) async throws -> Comparison {
        let range = try await diffRange(base, target, sinceMergeBase: sinceMergeBase)
        async let files = git.run(["-c", "core.quotepath=off", "diff", "--name-status", "-M", "-z"] + range + ["--"])
        // `git diff` only sees tracked files; on the working copy, new files count as added.
        async let untracked = target == nil
            ? git.run(["-c", "core.quotepath=off", "ls-files", "--others", "--exclude-standard", "-z"]).stdout
            : ""
        let tip = target ?? "HEAD"
        async let ahead = commits(in: "\(base)..\(tip)", limit: commitLimit)
        async let behind = commits(in: "\(tip)..\(base)", limit: commitLimit)
        let newFiles = try await untracked.split(separator: "\0").map {
            CommitFile(path: String($0), originalPath: nil, kind: .untracked)
        }
        let all = (Parsers.nameStatus(try await files.stdout) + newFiles).sorted { $0.path < $1.path }
        return Comparison(files: all, ahead: try await ahead, behind: try await behind)
    }

    /// Diff of one file between `base` and `target`, as in `compare`.
    public func diff(of file: CommitFile, from base: String, to target: String?,
                     sinceMergeBase: Bool = false) async throws -> [DiffLine] {
        if target == nil, file.kind == .untracked {
            // Exit code 1 just means "there are differences".
            let r = try await git.run(["-c", "core.quotepath=off", "diff", "--no-color", "--no-ext-diff",
                                       Repository.fullContext, "--no-index", "--", "/dev/null", file.path],
                                      allowFailure: true)
            return Parsers.diff(r.stdout)
        }
        let range = try await diffRange(base, target, sinceMergeBase: sinceMergeBase)
        let paths = ["--", file.path] + (file.originalPath.map { [$0] } ?? [])
        let r = try await git.run(["-c", "core.quotepath=off", "diff", "--no-color", "--no-ext-diff",
                                   Repository.fullContext, "-M"] + range + paths)
        return Parsers.diff(r.stdout)
    }

    private func diffRange(_ base: String, _ target: String?, sinceMergeBase: Bool) async throws -> [String] {
        switch (target, sinceMergeBase) {
        case (let target?, true): return ["\(base)...\(target)"]
        case (let target?, false): return [base, target]
        case (nil, true):
            let r = try await git.run(["merge-base", base, "HEAD"])
            return [r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)]
        case (nil, false): return [base]
        }
    }

    private func commits(in range: String, limit: Int) async throws -> [Commit] {
        let r = try await git.run(["-c", "log.showSignature=false", "log", "--decorate=full", "-n", String(limit),
                                   "--format=\(Parsers.logFormat)", range, "--"])
        return Parsers.log(r.stdout)
    }
}

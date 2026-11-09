import Foundation

public struct GitResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { exitCode == 0 }

    /// stderr + stdout, trimmed, for showing to the user.
    public var combinedOutput: String {
        [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public struct GitError: LocalizedError, Sendable {
    public let command: String
    public let output: String
    public init(command: String, output: String) {
        self.command = command
        self.output = output
    }
    public var errorDescription: String? {
        output.isEmpty ? "git \(command) failed." : output
    }
}

/// Runs the system `git` binary. Using the real CLI means hooks, credentials,
/// ~/.gitconfig and ~/.ssh/config all behave exactly like in Terminal.
public struct Git: Sendable {
    public static let executablePath = "/usr/bin/git"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    public func run(
        _ args: [String],
        allowFailure: Bool = false,
        environment extraEnv: [String: String] = [:]
    ) async throws -> GitResult {
        let dir = directory
        // A thread of its own, not Swift's shared pool: runSync blocks until git exits, and a
        // burst of commands (one refresh per open tab) used to fill every pool thread with
        // waiters while the work that reads git's output never got a thread, hanging them all.
        let result: GitResult = try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try Git.runSync(args, in: dir, extraEnv: extraEnv) })
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        if !allowFailure && !result.succeeded {
            throw GitError(command: args.joined(separator: " "), output: result.combinedOutput)
        }
        return result
    }

    static func environment(extra: [String: String], directory: URL? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Apps started from Finder get a minimal PATH; add Homebrew so git-lfs etc. resolve.
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        // Never block on an interactive username/password prompt.
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Don't take the index lock just to refresh stat info during `git status`.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // SSH: fail instead of hanging on a passphrase prompt; trust a host the first
        // time it is seen (same as answering "yes" once in Terminal).
        if env["GIT_SSH_COMMAND"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        }
        // The active profile: commit author and GitHub sign-in, without touching ~/.gitconfig.
        for (k, v) in GitIdentity.environment(for: directory) { env[k] = v }
        for (k, v) in extra { env[k] = v }
        return env
    }

    static func runSync(_ args: [String], in dir: URL, extraEnv: [String: String]) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.currentDirectoryURL = dir
        process.environment = environment(extra: extraEnv, directory: dir)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // Drain both pipes concurrently so a large stdout can't deadlock on a full stderr buffer.
        final class Box: @unchecked Sendable { var data = Data() }
        let outBox = Box()
        let group = DispatchGroup()
        group.enter()
        // Also a plain thread: a queue's worker might not start while git is waiting on it.
        Thread {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }.start()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return GitResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

/// Extra environment for every git command, set by the app from the active profile.
/// Empty means plain git: author and credentials come from your gitconfig as usual.
public enum GitIdentity {
    /// Repositories inside `folder` (or below it) use `environment`, whatever profile is active.
    public struct FolderRule: Sendable {
        public let folder: String
        public let environment: [String: String]
        public init(folder: String, environment: [String: String]) {
            self.folder = GitIdentity.normalize(folder)
            self.environment = environment
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: [String: String] = [:]
    nonisolated(unsafe) private static var folderRules: [FolderRule] = []

    /// The active profile: used where no folder rule matches.
    public static var environment: [String: String] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    public static var rules: [FolderRule] {
        get { lock.withLock { folderRules } }
        set { lock.withLock { folderRules = newValue } }
    }

    /// The deepest folder rule containing `directory`, else the active profile.
    public static func environment(for directory: URL?) -> [String: String] {
        lock.withLock {
            guard let directory, let rule = bestRule(for: directory.path, in: folderRules) else { return current }
            return rule.environment
        }
    }

    /// Index of the deepest folder in `folders` that contains `path`.
    public static func matchingFolder(_ path: String, in folders: [String]) -> Int? {
        let target = normalize(path)
        var best: (index: Int, length: Int)?
        for (i, folder) in folders.enumerated() {
            let f = normalize(folder)
            guard !f.isEmpty, target == f || target.hasPrefix(f.hasSuffix("/") ? f : f + "/") else { continue }
            if best == nil || f.count > best!.length { best = (i, f.count) }
        }
        return best?.index
    }

    private static func bestRule(for path: String, in rules: [FolderRule]) -> FolderRule? {
        matchingFolder(path, in: rules.map(\.folder)).map { rules[$0] }
    }

    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standard = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }

    /// Author/committer override plus, when a GitHub token is given, an auth header for
    /// https://github.com only (no credential helper or prompt involved).
    public static func environment(authorName: String, authorEmail: String, gitHubToken: String?) -> [String: String] {
        var env: [String: String] = [:]
        let name = authorName.trimmingCharacters(in: .whitespaces)
        let email = authorEmail.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            env["GIT_AUTHOR_NAME"] = name
            env["GIT_COMMITTER_NAME"] = name
        }
        if !email.isEmpty {
            env["GIT_AUTHOR_EMAIL"] = email
            env["GIT_COMMITTER_EMAIL"] = email
        }
        if let token = gitHubToken, !token.isEmpty {
            let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
            env["GIT_CONFIG_COUNT"] = "1"
            env["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
            env["GIT_CONFIG_VALUE_0"] = "Authorization: Basic \(basic)"
        }
        return env
    }
}

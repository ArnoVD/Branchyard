import Foundation

public struct GitHubUser: Decodable, Sendable, Hashable {
    public let id: Int
    public let login: String
    public let name: String?
    /// GitHub's private commit address: commits still link to your account.
    public var noReplyEmail: String { "\(id)+\(login)@users.noreply.github.com" }
}

public struct GitHubRepo: Decodable, Sendable, Hashable {
    public let fullName: String
    public let htmlURL: String
    public let cloneURL: String

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case htmlURL = "html_url"
        case cloneURL = "clone_url"
    }
}

/// GitHub REST API with a personal access token.
public struct GitHubClient: Sendable {
    public let token: String

    public init(token: String) { self.token = token }

    public func user() async throws -> GitHubUser {
        try await send("GET", "/user")
    }

    /// Creates an empty repository on your account.
    public func createRepository(name: String, description: String, isPrivate: Bool) async throws -> GitHubRepo {
        var body: [String: Any] = ["name": name, "private": isPrivate, "auto_init": false]
        if !description.isEmpty { body["description"] = description }
        return try await send("POST", "/user/repos", body: body)
    }

    private struct APIError: Decodable {
        struct Detail: Decodable { let message: String? }
        let message: String
        let errors: [Detail]?
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Branchyard", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let api = try? JSONDecoder().decode(APIError.self, from: data)
            let details = api?.errors?.compactMap(\.message).joined(separator: " ") ?? ""
            let message = [api?.message, details].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            let hint = code == 401 ? "The token was rejected. Check that it is correct and not expired."
                : code == 403 || code == 404 ? "The token lacks permission. It needs Administration (read & write) for creating repositories, or the classic \"repo\" scope."
                : ""
            throw GitError(command: "GitHub \(method) \(path)",
                           output: [message.isEmpty ? "GitHub returned \(code)." : message, hint].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

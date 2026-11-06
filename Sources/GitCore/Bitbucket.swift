import Foundation

/// A repository as returned by the Bitbucket Cloud REST API (api.bitbucket.org/2.0).
public struct BitbucketRepo: Identifiable, Hashable, Decodable, Sendable {
    public struct Links: Hashable, Decodable, Sendable {
        public struct CloneLink: Hashable, Decodable, Sendable {
            public let name: String
            public let href: String
        }
        public let clone: [CloneLink]?
    }

    public let uuid: String
    public let name: String
    public let fullName: String
    public let description: String?
    public let updatedOn: String?
    public let isPrivate: Bool?
    public let links: Links

    public var id: String { uuid }
    public var workspace: String { fullName.split(separator: "/").first.map(String.init) ?? "" }
    public var sshURL: String? { links.clone?.first { $0.name == "ssh" }?.href }

    enum CodingKeys: String, CodingKey {
        case uuid, name, description, links
        case fullName = "full_name"
        case updatedOn = "updated_on"
        case isPrivate = "is_private"
    }
}

/// Lists repositories with an Atlassian API token (Basic auth: account email + token).
/// Cloning itself goes over SSH with your normal ~/.ssh keys.
public struct BitbucketClient: Sendable {
    public let email: String
    public let apiToken: String

    public init(email: String, apiToken: String) {
        self.email = email
        self.apiToken = apiToken
    }

    private struct Page: Decodable {
        let values: [BitbucketRepo]
        let next: String?
    }

    /// All repositories you're a member of, or only those in `workspace` if given.
    public func repositories(workspace: String?) async throws -> [BitbucketRepo] {
        let ws = workspace?.trimmingCharacters(in: .whitespaces) ?? ""
        var components = URLComponents(string: "https://api.bitbucket.org/2.0/repositories")!
        if !ws.isEmpty {
            components.path += "/" + ws
        } else {
            components.queryItems = [URLQueryItem(name: "role", value: "member")]
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "pagelen", value: "100"),
            URLQueryItem(name: "sort", value: "-updated_on"),
        ]

        var next: URL? = components.url
        var all: [BitbucketRepo] = []
        var pages = 0
        while let url = next, pages < 30 {
            let page: Page = try await get(url)
            all += page.values
            next = page.next.flatMap(URL.init(string:))
            pages += 1
        }
        return all
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        let credentials = Data("\(email):\(apiToken)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let body = String(decoding: data.prefix(400), as: UTF8.self)
            let hint: String
            switch code {
            case 401: hint = "Bitbucket rejected the email/API token. Use your Atlassian account email and an API token with Bitbucket scopes."
            case 403: hint = "The API token is missing a scope. It needs read:repository:bitbucket (and read:workspace:bitbucket)."
            case 404: hint = "Workspace not found. Check the workspace ID (the part after bitbucket.org/ in your repo URLs)."
            default: hint = "Bitbucket returned HTTP \(code)."
            }
            throw GitError(command: "bitbucket", output: "\(hint)\n\n\(body)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

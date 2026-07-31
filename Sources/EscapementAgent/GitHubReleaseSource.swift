import EscapementKit
import Foundation

/// The one network call in the whole app (see spec 014). Fetches GitHub's
/// "latest release" for this repository — which only ever returns a
/// published, non-draft, non-prerelease release — and reports its tag and
/// page. Nothing is ever downloaded or executed; `UpdateChecker` in
/// `EscapementKit` decides what the tag means.
struct GitHubReleaseSource: UpdateSource {
    private static let endpoint = URL(
        string: "https://api.github.com/repos/granroth/escapement/releases/latest")!

    private struct Response: Decodable {
        let tagName: String
        let htmlURL: URL

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    func latestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: Self.endpoint)
        // GitHub's API refuses requests with no User-Agent header.
        request.setValue("Escapement-Agent", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateSourceError.badResponse
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return ReleaseInfo(tagName: decoded.tagName, releaseURL: decoded.htmlURL)
    }
}

enum UpdateSourceError: Error {
    case badResponse
}

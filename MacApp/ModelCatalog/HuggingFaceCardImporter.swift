import Foundation

enum HuggingFaceCardError: Error, LocalizedError {
    case invalidRepository, invalidResponse, tooLarge, privateRepository

    var errorDescription: String? {
        switch self {
        case .invalidRepository: processingText("Enter a public Hugging Face owner/repository, not a URL or local path.")
        case .invalidResponse: processingText("The public model card could not be read. No files were installed.")
        case .tooLarge: processingText("The model metadata or card exceeds the 512 KB safety limit.")
        case .privateRepository: processingText("Only public, ungated model cards are supported. Sign-in is never requested.")
        }
    }
}

/// No hub SDK, credentials, cookies, model weights, remote images, or executable code.
struct HuggingFaceCardImporter: Sendable {
    static let maximumBytes = 512 * 1_024

    static func repositoryID(_ input: String) throws -> String {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = input.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard pieces.count == 2, input.count <= 193,
              pieces.allSatisfy({ part in
                  !part.isEmpty && part != "." && part != ".."
                    && !part.hasPrefix(".") && !part.contains("..")
                    && part.unicodeScalars.allSatisfy(allowed.contains)
              }) else { throw HuggingFaceCardError.invalidRepository }
        return input
    }

    static func allowedURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "huggingface.co"
            && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil
    }

    func fetch(repository input: String, category: MacModelCategory) async throws -> MacModelCard {
        let repository = try Self.repositoryID(input)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let metadata = try await boundedData(
            URL(string: "https://huggingface.co/api/models/\(repository)")!, session: session)
        let decoded = try JSONDecoder().decode(Metadata.self, from: metadata)
        guard decoded.private != true, decoded.gated?.isGated != true else {
            throw HuggingFaceCardError.privateRepository
        }
        guard Self.validRevision(decoded.sha) else {
            throw HuggingFaceCardError.invalidResponse
        }
        let cardData = try await boundedData(
            URL(string: "https://huggingface.co/\(repository)/raw/\(decoded.sha)/README.md")!, session: session)
        return try Self.makeCard(repository: repository, category: category, metadata: metadata, cardData: cardData)
    }

    static func makeCard(
        repository: String, category: MacModelCategory, metadata: Data, cardData: Data
    ) throws -> MacModelCard {
        let repository = try repositoryID(repository)
        guard metadata.count <= maximumBytes, cardData.count <= maximumBytes else {
            throw HuggingFaceCardError.tooLarge
        }
        let decoded = try JSONDecoder().decode(Metadata.self, from: metadata)
        guard decoded.private != true, decoded.gated?.isGated != true else {
            throw HuggingFaceCardError.privateRepository
        }
        guard validRevision(decoded.sha) else { throw HuggingFaceCardError.invalidResponse }
        guard let card = String(data: cardData, encoding: .utf8) else {
            throw HuggingFaceCardError.invalidResponse
        }
        let files = decoded.siblings?.map(\.rfilename) ?? []
        var formats: [String] = []
        if files.contains(where: { $0.contains(".mlmodelc/") || $0.contains(".mlpackage/") }) { formats.append("Core ML") }
        for suffix in ["safetensors", "gguf", "onnx", "nemo", "bin", "pt"] {
            if files.contains(where: { $0.lowercased().hasSuffix("." + suffix) }) { formats.append(suffix) }
        }
        return MacModelCard(
            id: "hf:\(category.rawValue):\(repository)", name: repository, category: category,
            repository: repository, revision: decoded.sha,
            license: decoded.cardData?.license ?? "Not declared in metadata",
            artifactFormat: formats.isEmpty ? "Not declared in metadata" : formats.joined(separator: ", "),
            adapter: .cardOnly, cardText: card)
    }

    private static func validRevision(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private func boundedData(_ url: URL, session: URLSession) async throws -> Data {
        guard Self.allowedURL(url) else { throw HuggingFaceCardError.invalidRepository }
        var request = URLRequest(url: url)
        request.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url.map(Self.allowedURL) == true else { throw HuggingFaceCardError.invalidResponse }
        if [401, 403].contains(response.statusCode) { throw HuggingFaceCardError.privateRepository }
        guard response.statusCode == 200 else { throw HuggingFaceCardError.invalidResponse }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else { throw HuggingFaceCardError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumBytes else { throw HuggingFaceCardError.tooLarge }
            data.append(byte)
        }
        return data
    }

    private struct Metadata: Decodable {
        let sha: String
        let `private`: Bool?
        let gated: Gated?
        let cardData: CardData?
        let siblings: [Sibling]?
        struct CardData: Decodable { let license: String? }
        struct Sibling: Decodable { let rfilename: String }
        enum Gated: Decodable {
            case boolean(Bool), text(String)
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let boolean = try? container.decode(Bool.self) { self = .boolean(boolean) }
                else { self = .text(try container.decode(String.self)) }
            }
            var isGated: Bool {
                switch self { case .boolean(let value): value; case .text(let value): value != "false" }
            }
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                              ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }
}

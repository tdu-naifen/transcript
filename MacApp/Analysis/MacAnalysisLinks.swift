import Foundation

enum MacAnalysisLinks {
    static func citation(for url: URL, allowed: [MacAnalysisCitation]) -> MacAnalysisCitation? {
        guard url.scheme == "transcript-evidence", url.host == "source",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let id = String(url.path.dropFirst())
        return allowed.first { $0.evidenceID == id && url.path == "/\(id)" }
    }
}

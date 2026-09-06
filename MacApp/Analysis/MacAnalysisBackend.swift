import Foundation
import FoundationModels

enum MacAnalysisAvailability: Equatable, Sendable {
    case checking, available, unavailable(String)

    var message: String {
        switch self {
        case .checking: String(localized: "Checking on-device model…")
        case .available: String(localized: "Apple on-device model ready")
        case .unavailable(let reason): reason
        }
    }
}

protocol MacAnalysisGenerating: Sendable {
    func availability() async -> MacAnalysisAvailability
    func generate(_ request: MacAnalysisRequest) async throws -> String
}

actor MacFoundationModelsBackend: MacAnalysisGenerating {
    func availability() async -> MacAnalysisAvailability {
        guard #available(macOS 26.0, *) else {
            return .unavailable(String(localized: "On-device analysis requires macOS 26 or later."))
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(String(localized: "This Mac does not support Apple Intelligence."))
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(String(localized: "Enable Apple Intelligence in System Settings to use on-device analysis."))
        case .unavailable(.modelNotReady):
            return .unavailable(String(localized: "The Apple on-device model is not ready. Check Apple Intelligence in System Settings, then retry."))
        case .unavailable:
            return .unavailable(String(localized: "The Apple on-device model is unavailable on this Mac."))
        }
    }

    func generate(_ request: MacAnalysisRequest) async throws -> String {
        let state = await availability()
        guard state == .available else { throw MacAnalysisError.unavailable(state.message) }
        guard request.inputByteCount <= MacAnalysisEvidence.maximumInputBytes else {
            throw MacAnalysisError.questionTooLong
        }
        guard #available(macOS 26.0, *) else {
            throw MacAnalysisError.unavailable(state.message)
        }
        try Task.checkCancellation()
        // Each request gets a fresh, tool-free session, so hidden session history
        // cannot silently grow past the 4,096-token context window.
        let session = LanguageModelSession(instructions: request.instructions)
        let options = GenerationOptions(
            temperature: 0.2, maximumResponseTokens: MacAnalysisEvidence.maximumResponseTokens
        )
        if request.mode != .chat {
            let response = try await session.respond(
                to: request.prompt, generating: NativeGroundedResponse.self, options: options
            )
            try Task.checkCancellation()
            return String(decoding: try JSONEncoder().encode(response.content), as: UTF8.self)
        }
        let response = try await session.respond(
            to: request.prompt, options: options
        )
        try Task.checkCancellation()
        return response.content
    }
}

@available(macOS 26.0, *)
@Generable
private struct NativeGroundedResponse: Codable, Sendable {
    @Guide(description: "True only when the supplied evidence cannot answer. Then paragraphs must be empty.")
    var noEvidence: Bool
    @Guide(description: "Supported claims only. Empty if noEvidence is true.", .count(0...6))
    var paragraphs: [NativeGroundedParagraph]
}

@available(macOS 26.0, *)
@Generable
private struct NativeGroundedParagraph: Codable, Sendable {
    @Guide(description: "One concise claim supported by the cited excerpts.")
    var text: String
    @Guide(description: "Supporting evidence IDs copied exactly from the supplied records, for example E1. Never empty.", .count(1...6))
    var evidenceIDs: [String]
}

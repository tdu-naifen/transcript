import Foundation

/// Which language the model is prompted with. `auto` makes it emit a `<xx-XX>` tag
/// after terminal punctuation instead of being told up front.
public enum ASRLanguage: Sendable, Hashable, Codable {
    case auto
    case locale(String)

    public var promptKey: String {
        switch self {
        case .auto: "auto"
        case .locale(let identifier): identifier
        }
    }

    /// The identifier to stamp on an utterance when the model is *not* auto-detecting.
    public var fixedLocaleIdentifier: String? {
        switch self {
        case .auto: nil
        case .locale(let identifier): identifier
        }
    }
}


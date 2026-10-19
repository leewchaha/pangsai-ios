import Foundation

public enum HandleRules {
    public static let minLength = 2
    public static let maxLength = 20

    public enum Problem: Equatable, Sendable {
        case tooShort, tooLong, invalidCharacters, badDots, notAllowed

        public var message: String {
            switch self {
            case .tooShort: return "At least \(HandleRules.minLength) characters."
            case .tooLong: return "\(HandleRules.maxLength) characters max."
            case .invalidCharacters: return "English letters (a–z), numbers, dots and underscores only."
            case .badDots: return "No dots at the start, end, or twice in a row."
            case .notAllowed: return "Pick a different handle."
            }
        }
    }

    /// Lowercases, trims, removes a leading "@".
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasPrefix("@") { s.removeFirst() }
        return s
    }

    public static func validate(_ raw: String) -> Problem? {
        let h = normalize(raw)
        if h.count < minLength { return .tooShort }
        if h.count > maxLength { return .tooLong }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._")
        if !h.allSatisfy({ allowed.contains($0) }) { return .invalidCharacters }
        if h.hasPrefix(".") || h.hasSuffix(".") || h.contains("..") { return .badDots }
        if ContentFilter.isBlocked(h) { return .notAllowed }
        return nil
    }

    /// Duplicate handles inside one group render as "@lee (1)", "@lee (2)".
    /// Ordering is deterministic: earliest joiner first, then user id. Labels are recomputed
    /// every render so they disappear as soon as the conflict does.
    public static func groupLabels(_ members: [(id: UserID, handle: String, joinedAt: Date)]) -> [UserID: String] {
        var byHandle: [String: [(id: UserID, handle: String, joinedAt: Date)]] = [:]
        for m in members { byHandle[normalize(m.handle), default: []].append(m) }
        var out: [UserID: String] = [:]
        for (_, list) in byHandle {
            if list.count == 1, let only = list.first {
                out[only.id] = "@" + normalize(only.handle)
                continue
            }
            let ordered = list.sorted { $0.joinedAt != $1.joinedAt ? $0.joinedAt < $1.joinedAt : $0.id < $1.id }
            for (i, m) in ordered.enumerated() {
                out[m.id] = "@\(normalize(m.handle)) (\(i + 1))"
            }
        }
        return out
    }
}

/// Minimal moderation for the only free text in v1: handles and group names.
public enum ContentFilter {
    /// Substrings that are never allowed. Kept short and conservative; extend server-free as needed.
    static let blocked: [String] = [
        "nigg", "fagg", "retard", "kike", "chink", "tranny", "nazi", "hitler", "kkk"
    ]

    public static func isBlocked(_ text: String) -> Bool {
        let folded = text.lowercased()
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "i")
            .replacingOccurrences(of: "3", with: "e")
            .replacingOccurrences(of: "4", with: "a")
            .replacingOccurrences(of: "5", with: "s")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        return blocked.contains { folded.contains($0) }
    }

    public static func cleanGroupName(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 28, !isBlocked(s) else { return nil }
        return s
    }
}

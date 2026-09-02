import Foundation

struct AudioTrackSelectionCandidate {
    let streamIndex: Int
    let audioIndex: Int
    let language: String?
    let title: String?
    let handlerName: String?
    let codec: String?
    let profile: String?
    let channels: Int?
    let channelLayout: String?
    let bitRate: Int?
    let duration: TimeInterval?
    let isDefault: Bool
    let isCommentary: Bool
    let isVisualImpaired: Bool
    let isDub: Bool
}

enum AudioTrackRole: String {
    case main
    case commentary
    case audioDescription
    case dub
}

enum AudioTrackSelectionPolicy {
    static func selectedCandidates(
        from candidates: [AudioTrackSelectionCandidate],
        keepEnglishOnly: Bool,
        keepAllEnglishTracks: Bool
    ) -> [AudioTrackSelectionCandidate] {
        guard !candidates.isEmpty else { return [] }

        let english = candidates.filter(isEnglish)
        let undefined = candidates.filter(isUndefinedLanguage)

        if keepEnglishOnly {
            let languageCandidates = english.isEmpty ? undefined : english
            guard !languageCandidates.isEmpty else { return [] }
            if keepAllEnglishTracks {
                return languageCandidates
            }
            return preferredMainTrack(from: languageCandidates).map { [$0] } ?? []
        }

        guard !english.isEmpty, !keepAllEnglishTracks else {
            return candidates
        }

        guard let preferredEnglish = preferredMainTrack(from: english) else {
            return candidates
        }
        let retainedIndexes = Set(
            candidates
                .filter { !isEnglish($0) }
                .map(\.streamIndex)
                + [preferredEnglish.streamIndex]
        )
        return candidates.filter { retainedIndexes.contains($0.streamIndex) }
    }

    static func preferredMainTrack(
        from candidates: [AudioTrackSelectionCandidate]
    ) -> AudioTrackSelectionCandidate? {
        guard !candidates.isEmpty else { return nil }
        let ordinary = candidates.filter { role(of: $0) == .main }
        let pool = ordinary.isEmpty ? candidates : ordinary
        let longestDuration = pool.compactMap(\.duration).max()

        return pool.max { lhs, rhs in
            let lhsScore = score(lhs, longestDuration: longestDuration)
            let rhsScore = score(rhs, longestDuration: longestDuration)
            if lhsScore == rhsScore {
                return lhs.audioIndex > rhs.audioIndex
            }
            return lhsScore < rhsScore
        }
    }

    static func role(of candidate: AudioTrackSelectionCandidate) -> AudioTrackRole {
        let label = normalizedLabel(candidate)
        if candidate.isCommentary
            || containsAny(label, [
                "commentary", "director's comment", "directors comment",
                "producer's comment", "producers comment", "cast comment"
            ]) {
            return .commentary
        }
        if candidate.isVisualImpaired
            || containsAny(label, [
                "audio description", "audio descriptive", "descriptive audio",
                "described video", "vision impaired"
            ]) {
            return .audioDescription
        }
        if candidate.isDub || containsAny(label, ["dubbed", "dub track"]) {
            return .dub
        }
        return .main
    }

    static func isEnglish(_ candidate: AudioTrackSelectionCandidate) -> Bool {
        let language = normalized(candidate.language)
        return language == "eng" || language == "en"
    }

    static func isUndefinedLanguage(_ candidate: AudioTrackSelectionCandidate) -> Bool {
        let language = normalized(candidate.language)
        return language.isEmpty || language == "und"
    }

    static func summary(for candidate: AudioTrackSelectionCandidate) -> String {
        let codec = displayCodec(candidate.codec)
        let layout = displayLayout(candidate)
        return [codec, layout].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func score(
        _ candidate: AudioTrackSelectionCandidate,
        longestDuration: TimeInterval?
    ) -> Int {
        var value = 0

        switch candidate.channels {
        case 6: value += 400
        case 2: value += 300
        case 8: value += 250
        case 1: value += 200
        case let channels?: value += min(max(channels, 0), 10) * 20
        case nil: break
        }

        switch normalized(candidate.codec) {
        case "aac": value += 140
        case "eac3": value += 120
        case "ac3": value += 110
        case "alac": value += 100
        case "mp3": value += 80
        default: break
        }

        if candidate.isDefault { value += 35 }
        if normalizedLabel(candidate).contains("repaired") { value += 20 }
        if let bitRate = candidate.bitRate {
            value += min(bitRate / 64_000, 12)
        }

        if let longestDuration,
           longestDuration > 0,
           let duration = candidate.duration,
           duration < longestDuration * 0.95 {
            value -= 1_000
        }

        return value
    }

    private static func normalizedLabel(_ candidate: AudioTrackSelectionCandidate) -> String {
        [candidate.title, candidate.handlerName]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func displayCodec(_ codec: String?) -> String {
        switch normalized(codec) {
        case "aac": return "AAC"
        case "eac3": return "E-AC-3"
        case "ac3": return "AC-3"
        case "alac": return "ALAC"
        case "mp3": return "MP3"
        case let value: return value.uppercased()
        }
    }

    private static func displayLayout(_ candidate: AudioTrackSelectionCandidate) -> String {
        switch candidate.channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let channels?: return "\(channels) channels"
        case nil: return candidate.channelLayout ?? ""
        }
    }
}

import Foundation

struct SubtitleTrackSelectionCandidate {
    let streamIndex: Int
    let subtitleIndex: Int
    let language: String?
    let title: String?
    let handlerName: String?
    let cueCount: Int?
    let accessibilityMarkerCount: Int
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isCaptions: Bool
}

enum SubtitleTrackRole: String {
    case ordinary
    case sdh
    case forced
}

struct SubtitleTrackSelection {
    let selected: [SubtitleTrackSelectionCandidate]
    let preferred: SubtitleTrackSelectionCandidate?
    let rationale: String?
}

enum SubtitleTrackSelectionPolicy {
    static func select(
        from candidates: [SubtitleTrackSelectionCandidate],
        keepEnglishOnly: Bool,
        keepAllEnglishTracks: Bool
    ) -> SubtitleTrackSelection {
        guard !candidates.isEmpty else {
            return SubtitleTrackSelection(selected: [], preferred: nil, rationale: nil)
        }

        let english = candidates.filter(isEnglish)
        let undefined = candidates.filter(isUndefinedLanguage)
        let englishPool = english.isEmpty ? undefined : english
        let preferred = preferredFullTrack(from: englishPool)

        let selected: [SubtitleTrackSelectionCandidate]
        if keepEnglishOnly {
            if keepAllEnglishTracks {
                selected = englishPool
            } else {
                selected = preferred.map { [$0] } ?? []
            }
        } else if keepAllEnglishTracks || english.isEmpty {
            selected = candidates
        } else if let preferred {
            selected = candidates.filter { !isEnglish($0) || $0.streamIndex == preferred.streamIndex }
        } else {
            selected = candidates
        }

        return SubtitleTrackSelection(
            selected: selected,
            preferred: preferred,
            rationale: preferred.map { rationale(for: $0, among: englishPool) }
        )
    }

    static func preferredFullTrack(
        from candidates: [SubtitleTrackSelectionCandidate]
    ) -> SubtitleTrackSelectionCandidate? {
        guard !candidates.isEmpty else { return nil }
        let maximumCueCount = candidates.compactMap(\.cueCount).max()

        return candidates.max { lhs, rhs in
            let lhsScore = score(lhs, maximumCueCount: maximumCueCount)
            let rhsScore = score(rhs, maximumCueCount: maximumCueCount)
            if lhsScore == rhsScore {
                return lhs.subtitleIndex > rhs.subtitleIndex
            }
            return lhsScore < rhsScore
        }
    }

    static func role(
        of candidate: SubtitleTrackSelectionCandidate,
        maximumCueCount: Int? = nil
    ) -> SubtitleTrackRole {
        let label = normalizedLabel(candidate)
        if candidate.isForced || label.contains("forced") {
            return .forced
        }

        if let maximumCueCount,
           maximumCueCount >= 20,
           let cueCount = candidate.cueCount,
           cueCount < max(10, Int(Double(maximumCueCount) * 0.35)) {
            return .forced
        }

        if candidate.isHearingImpaired
            || candidate.isCaptions
            || containsAny(label, ["sdh", "hearing impaired", "closed caption", "closed-caption", "cc"]) {
            return .sdh
        }

        if let cueCount = candidate.cueCount,
           cueCount > 0,
           candidate.accessibilityMarkerCount >= max(5, Int(Double(cueCount) * 0.03)) {
            return .sdh
        }

        return .ordinary
    }

    static func isEnglish(_ candidate: SubtitleTrackSelectionCandidate) -> Bool {
        let language = normalized(candidate.language)
        if language == "eng" || language == "en" { return true }
        let label = normalizedLabel(candidate)
        return label.contains("english")
    }

    static func isUndefinedLanguage(_ candidate: SubtitleTrackSelectionCandidate) -> Bool {
        let language = normalized(candidate.language)
        return language.isEmpty || language == "und"
    }

    static func rationale(
        for candidate: SubtitleTrackSelectionCandidate,
        among candidates: [SubtitleTrackSelectionCandidate]
    ) -> String {
        let maximumCueCount = candidates.compactMap(\.cueCount).max()
        let role = role(of: candidate, maximumCueCount: maximumCueCount)
        let roleName: String
        switch role {
        case .ordinary: roleName = "complete ordinary English"
        case .sdh: roleName = "complete English SDH"
        case .forced: roleName = "English forced-only fallback"
        }

        var details = [roleName]
        if let cueCount = candidate.cueCount {
            details.append("\(cueCount) cues")
        }
        if candidate.accessibilityMarkerCount > 0 {
            details.append("\(candidate.accessibilityMarkerCount) accessibility cue(s)")
        }
        return details.joined(separator: " · ")
    }

    static func contentMetrics(from subtitleText: String) -> (
        cueCount: Int,
        accessibilityMarkerCount: Int
    ) {
        let lines = subtitleText.components(separatedBy: .newlines)
        let cueCount = lines.reduce(into: 0) { count, line in
            if line.contains("-->") { count += 1 }
        }

        var markers = 0
        for rawLine in lines {
            let line = rawLine
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.contains("-->") else { continue }

            if line.contains("♪") || line.contains("♫") {
                markers += 1
                continue
            }
            if (line.hasPrefix("[") && line.contains("]"))
                || (line.hasPrefix("(") && line.hasSuffix(")")) {
                markers += 1
                continue
            }
            if line.range(
                of: #"^[A-Z][A-Z0-9 .'-]{1,24}:\s+"#,
                options: .regularExpression
            ) != nil {
                markers += 1
            }
        }
        return (cueCount, markers)
    }

    private static func score(
        _ candidate: SubtitleTrackSelectionCandidate,
        maximumCueCount: Int?
    ) -> Int {
        let resolvedRole = role(of: candidate, maximumCueCount: maximumCueCount)
        var value: Int
        switch resolvedRole {
        case .ordinary: value = 300_000
        case .sdh: value = 200_000
        case .forced: value = 100_000
        }

        if let maximumCueCount, maximumCueCount > 0, let cueCount = candidate.cueCount {
            value += Int((Double(cueCount) / Double(maximumCueCount)) * 10_000)
        }

        // When two complete tracks are unlabeled, the one with fewer music,
        // sound-description, and speaker-label cues is usually the ordinary track.
        value -= min(candidate.accessibilityMarkerCount, 10_000) * 20
        if candidate.isDefault && resolvedRole != .forced { value += 50 }
        return value
    }

    private static func normalizedLabel(_ candidate: SubtitleTrackSelectionCandidate) -> String {
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
}

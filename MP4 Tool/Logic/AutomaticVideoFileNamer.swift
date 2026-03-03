import Foundation

enum AutomaticVideoFileNamer {
    private static let seasonEpisodeRegex = try! NSRegularExpression(
        pattern: #"(?i)\bS\s*(\d{1,2})\s*[\.\-_\s]*E\s*(\d{1,2})\b"#
    )
    private static let seasonXEpisodeRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(\d{1,2})x(\d{1,2})\b"#
    )
    private static let yearRegex = try! NSRegularExpression(
        pattern: #"\b(19\d{2}|20\d{2}|21\d{2})\b"#
    )
    private static let metadataTokens: Set<String> = [
        "10bit", "2160p", "1080p", "720p", "480p", "4k", "8k",
        "aac", "atmos", "bdrip", "bluray", "brip", "brrip", "cam", "ddp5", "ddp51", "dd51",
        "dvdrip", "h264", "h265", "hdr", "hdr10", "hdrip", "hevc", "proper", "repack", "remux",
        "uhd", "web", "webdl", "webrip", "x264", "x265", "yts"
    ]

    static func suggestedOutputFileName(
        fromInputFileName inputFileName: String,
        outputExtension: String = "mp4",
        fallbackSuffix: String? = nil
    ) -> String {
        let rawBaseName = (inputFileName as NSString).deletingPathExtension
        let baseNameForFallback = rawBaseName.isEmpty ? "output" : rawBaseName
        let ext = outputExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let finalExtension = ext.isEmpty ? "mp4" : ext

        if let suggestedBase = suggestedBaseName(fromRawBaseName: rawBaseName), !suggestedBase.isEmpty {
            return "\(suggestedBase).\(finalExtension)"
        }

        if let fallbackSuffix, !fallbackSuffix.isEmpty {
            return "\(baseNameForFallback)\(fallbackSuffix).\(finalExtension)"
        }

        return "\(baseNameForFallback).\(finalExtension)"
    }

    private static func suggestedBaseName(fromRawBaseName rawBaseName: String) -> String? {
        if let showName = suggestedTVShowBaseName(fromRawBaseName: rawBaseName) {
            return showName
        }

        if let movieName = suggestedMovieBaseName(fromRawBaseName: rawBaseName) {
            return movieName
        }

        return nil
    }

    private static func suggestedTVShowBaseName(fromRawBaseName rawBaseName: String) -> String? {
        let nsRaw = rawBaseName as NSString
        let fullRange = NSRange(location: 0, length: nsRaw.length)

        if let match = seasonEpisodeRegex.firstMatch(in: rawBaseName, options: [], range: fullRange) {
            return formattedShowName(fromRawString: nsRaw, match: match)
        }

        if let match = seasonXEpisodeRegex.firstMatch(in: rawBaseName, options: [], range: fullRange) {
            return formattedShowName(fromRawString: nsRaw, match: match)
        }

        return nil
    }

    private static func formattedShowName(fromRawString rawString: NSString, match: NSTextCheckingResult) -> String? {
        guard match.numberOfRanges >= 3 else { return nil }
        let seasonRange = match.range(at: 1)
        let episodeRange = match.range(at: 2)
        guard seasonRange.location != NSNotFound, episodeRange.location != NSNotFound else { return nil }

        let seasonText = rawString.substring(with: seasonRange)
        let episodeText = rawString.substring(with: episodeRange)
        guard let season = Int(seasonText), let episode = Int(episodeText) else { return nil }

        let showPrefix = rawString.substring(to: match.range.location)
        let showTokens = cleanedTitleTokens(from: showPrefix)
        guard !showTokens.isEmpty else { return nil }

        var showYear: String?
        var titleTokens: [String] = []
        titleTokens.reserveCapacity(showTokens.count)

        for token in showTokens {
            let normalized = normalizedToken(token)
            if showYear == nil, isYearToken(normalized) {
                showYear = normalized
                continue
            }
            titleTokens.append(token)
        }

        guard !titleTokens.isEmpty else { return nil }

        let showTitle = titleTokens.map(titleCaseToken).joined(separator: " ")
        let showName = showYear.map { "\(showTitle) (\($0))" } ?? showTitle
        return "\(showName) - S\(twoDigit(season))E\(twoDigit(episode))"
    }

    private static func suggestedMovieBaseName(fromRawBaseName rawBaseName: String) -> String? {
        let tokens = cleanedTitleTokens(from: rawBaseName)
        guard !tokens.isEmpty else { return nil }

        var year: String?
        var titleTokens: [String] = []
        titleTokens.reserveCapacity(tokens.count)

        for token in tokens {
            let normalized = normalizedToken(token)

            if year == nil, isYearToken(normalized) {
                year = normalized
                continue
            }

            if isMetadataToken(normalized) {
                continue
            }

            if year == nil {
                titleTokens.append(token)
            }
        }

        guard let year else { return nil }
        guard !titleTokens.isEmpty else { return nil }

        let title = titleTokens.map(titleCaseToken).joined(separator: " ")
        return "\(title) (\(year))"
    }

    private static func cleanedTitleTokens(from value: String) -> [String] {
        let separatorsNormalized = value
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        let rawTokens = separatorsNormalized
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'&"))
        var tokens: [String] = []
        tokens.reserveCapacity(rawTokens.count)

        for token in rawTokens {
            let trimmed = token.trimmingCharacters(in: allowed.inverted)
            if !trimmed.isEmpty {
                tokens.append(trimmed)
            }
        }

        return tokens
    }

    private static func normalizedToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
    }

    private static func isYearToken(_ token: String) -> Bool {
        let nsToken = token as NSString
        let range = NSRange(location: 0, length: nsToken.length)
        guard let match = yearRegex.firstMatch(in: token, options: [], range: range) else {
            return false
        }
        return match.range.location == 0 && match.range.length == nsToken.length
    }

    private static func isMetadataToken(_ token: String) -> Bool {
        if metadataTokens.contains(token) {
            return true
        }

        if ["480", "576", "720", "1080", "1440", "2160"].contains(token) {
            return true
        }

        if token.hasPrefix("x26"), token.count == 4 {
            return true
        }

        return false
    }

    private static func titleCaseToken(_ token: String) -> String {
        if token.count <= 4, token == token.uppercased() {
            return token
        }

        if token.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            return token
        }

        return token.capitalized(with: Locale.current)
    }

    private static func twoDigit(_ value: Int) -> String {
        String(format: "%02d", max(0, value))
    }
}

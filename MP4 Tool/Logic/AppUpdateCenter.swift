//
//  AppUpdateCenter.swift
//  MP4 Tool
//
//  Created by Codex on 2/18/26.
//
//  Purpose:
//  Provides a reusable app-level update check flow backed by GitHub tags,
//  including launch-time checks and manual checks from menu/About surfaces.

import AppKit
import Combine
import Foundation

/// Main-actor coordinator for "Check for Updates" behavior across the app.
@MainActor
final class AppUpdateCenter: ObservableObject {
    static let shared = AppUpdateCenter()

    @Published private(set) var isChecking = false
    @Published private(set) var lastStatusMessage: String?
    @Published private(set) var availableUpdate: AppAvailableUpdate?

    private var activeCheckTask: Task<Void, Never>?
    private var didRunAutomaticLaunchCheck = false
    private var checkInvocationCount = 0
    private let checker = GitHubTagUpdateChecker()

    private init() {}

    func dismissAvailableUpdate() {
        availableUpdate = nil
    }

    func openAvailableUpdateDownloadPage() {
        guard let releaseURL = availableUpdate?.releaseURL else { return }
        NSWorkspace.shared.open(releaseURL)
        availableUpdate = nil
    }

    func checkForUpdates(trigger: UpdateCheckTrigger = .manual) {
        checkInvocationCount += 1
        let invocationID = checkInvocationCount
        Self.debugLog(
            "checkForUpdates[\(invocationID)] trigger=\(trigger.logLabel) isChecking=\(isChecking) activeTask=\(activeCheckTask != nil)"
        )

        if trigger == .automaticLaunch {
            guard !didRunAutomaticLaunchCheck else {
                Self.debugLog("checkForUpdates[\(invocationID)] skipped: automatic launch already ran")
                return
            }
            didRunAutomaticLaunchCheck = true
            Self.debugLog("checkForUpdates[\(invocationID)] marked automatic launch check as consumed")
            runAutomaticLaunchCheck(invocationID: invocationID)
            return
        }

        runManualCheck(invocationID: invocationID)
    }

    private func runManualCheck(invocationID: Int) {
        guard activeCheckTask == nil else {
            Self.debugLog("checkForUpdates[\(invocationID)] skipped: another check is already in progress")
            return
        }

        guard let configuration = AppUpdateConfiguration.current() else {
            let message = "Update checking is not configured for this app."
            lastStatusMessage = message
            Self.debugLog("checkForUpdates[\(invocationID)] failed: configuration missing")
            presentInfoAlert(title: "Check for Updates", message: message)
            return
        }

        Self.debugLog(
            "checkForUpdates[\(invocationID)] starting manual check for repo=\(configuration.owner)/\(configuration.repository) currentVersion=\(configuration.currentVersion)"
        )

        isChecking = true
        lastStatusMessage = "Checking for updates..."

        let checker = self.checker
        activeCheckTask = Task.detached(priority: .utility) {
            let startTime = Date()
            do {
                AppUpdateCenter.debugLog("checkForUpdates[\(invocationID)] detached manual worker started")
                let latest = try await checker.latestVersionDetails(
                    owner: configuration.owner,
                    repository: configuration.repository,
                    userAgent: configuration.appName
                )
                AppUpdateCenter.debugLog("checkForUpdates[\(invocationID)] latest tag fetched: \(latest.tagName)")

                await MainActor.run {
                    let center = AppUpdateCenter.shared
                    defer {
                        center.isChecking = false
                        center.activeCheckTask = nil
                        let elapsed = Date().timeIntervalSince(startTime)
                        AppUpdateCenter.debugLog("checkForUpdates[\(invocationID)] manual finished in \(String(format: "%.2fs", elapsed))")
                    }

                    let currentVersion = configuration.currentVersion
                    let latestVersion = latest.tagName
                    let isNewer = VersionStringComparator.isVersion(latestVersion, greaterThan: currentVersion)
                    AppUpdateCenter.debugLog(
                        "checkForUpdates[\(invocationID)] manual compare latest=\(latestVersion) current=\(currentVersion) isNewer=\(isNewer)"
                    )

                    if isNewer {
                        let message = "Version \(latestVersion) is available. You have \(currentVersion)."
                        center.lastStatusMessage = message
                        let releaseURL = latest.releaseURL ?? configuration.releaseURL(for: latestVersion)
                        center.availableUpdate = AppAvailableUpdate(
                            appName: configuration.appName,
                            latestVersion: latestVersion,
                            currentVersion: currentVersion,
                            message: message,
                            releaseNotes: latest.releaseNotes,
                            releaseURL: releaseURL
                        )
                        AppUpdateCenter.debugLog("checkForUpdates[\(invocationID)] presented update overlay")
                        return
                    }

                    let message = "You're up to date (\(currentVersion))."
                    center.lastStatusMessage = message
                    center.presentInfoAlert(title: "Check for Updates", message: message)
                }
            } catch {
                AppUpdateCenter.debugLog("checkForUpdates[\(invocationID)] manual network/error failure: \(error.localizedDescription)")
                await MainActor.run {
                    let center = AppUpdateCenter.shared
                    defer {
                        center.isChecking = false
                        center.activeCheckTask = nil
                        let elapsed = Date().timeIntervalSince(startTime)
                        AppUpdateCenter.debugLog("checkForUpdates[\(invocationID)] manual failed in \(String(format: "%.2fs", elapsed))")
                    }

                    let message = "Could not check for updates. \(error.localizedDescription)"
                    center.lastStatusMessage = message
                    center.presentInfoAlert(title: "Check for Updates", message: message)
                }
            }
        }
    }

    private func runAutomaticLaunchCheck(invocationID: Int) {
        guard activeCheckTask == nil else {
            Self.debugLog("checkForUpdates[\(invocationID)] automatic skipped: another check is already in progress")
            return
        }

        guard let configuration = AppUpdateConfiguration.current() else {
            Self.debugLog("checkForUpdates[\(invocationID)] automatic skipped: configuration missing")
            return
        }

        Self.debugLog(
            "checkForUpdates[\(invocationID)] starting automatic check for repo=\(configuration.owner)/\(configuration.repository) currentVersion=\(configuration.currentVersion)"
        )

        let checker = self.checker
        activeCheckTask = Task.detached(priority: .utility) {
            let startTime = Date()
            do {
                AppUpdateCenter.debugLog("checkForUpdates[\(invocationID)] detached automatic worker started")
                let latest = try await checker.latestVersionDetails(
                    owner: configuration.owner,
                    repository: configuration.repository,
                    userAgent: configuration.appName
                )

                await MainActor.run {
                    let center = AppUpdateCenter.shared
                    defer {
                        center.activeCheckTask = nil
                        let elapsed = Date().timeIntervalSince(startTime)
                        AppUpdateCenter.debugLog("checkForUpdates[\(invocationID)] automatic finished in \(String(format: "%.2fs", elapsed))")
                    }

                    let currentVersion = configuration.currentVersion
                    let latestVersion = latest.tagName
                    let isNewer = VersionStringComparator.isVersion(latestVersion, greaterThan: currentVersion)
                    AppUpdateCenter.debugLog(
                        "checkForUpdates[\(invocationID)] automatic compare latest=\(latestVersion) current=\(currentVersion) isNewer=\(isNewer)"
                    )

                    guard isNewer else { return }

                    let message = "Version \(latestVersion) is available. You have \(currentVersion)."
                    let releaseURL = latest.releaseURL ?? configuration.releaseURL(for: latestVersion)
                    center.availableUpdate = AppAvailableUpdate(
                        appName: configuration.appName,
                        latestVersion: latestVersion,
                        currentVersion: currentVersion,
                        message: message,
                        releaseNotes: latest.releaseNotes,
                        releaseURL: releaseURL
                    )
                    AppUpdateCenter.debugLog("checkForUpdates[\(invocationID)] automatic presented update overlay")
                }
            } catch {
                AppUpdateCenter.debugLog("checkForUpdates[\(invocationID)] automatic network/error failure: \(error.localizedDescription)")
                await MainActor.run {
                    let center = AppUpdateCenter.shared
                    center.activeCheckTask = nil
                    let elapsed = Date().timeIntervalSince(startTime)
                    AppUpdateCenter.debugLog("checkForUpdates[\(invocationID)] automatic failed in \(String(format: "%.2fs", elapsed))")
                }
            }
        }
    }

    nonisolated static func debugLog(_ message: String) {
#if DEBUG
        let thread = Thread.isMainThread ? "main" : "bg"
        print("[UpdateDebug][\(thread)] \(message)")
#endif
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Describes how an update check was initiated.
enum UpdateCheckTrigger: Sendable {
    case automaticLaunch
    case manual

    var logLabel: String {
        switch self {
        case .automaticLaunch:
            return "automaticLaunch"
        case .manual:
            return "manual"
        }
    }
}

struct AppAvailableUpdate: Identifiable, Sendable {
    let id = UUID()
    let appName: String
    let latestVersion: String
    let currentVersion: String
    let message: String
    let releaseNotes: String?
    let releaseURL: URL?
}

/// Info.plist-backed update configuration so this helper can be reused in other apps.
private struct AppUpdateConfiguration: Sendable {
    let appName: String
    let currentVersion: String
    let owner: String
    let repository: String
    let releasesPageURL: URL?

    func releaseURL(for tag: String) -> URL? {
        guard let releasesPageURL else {
            return URL(string: "https://github.com/\(owner)/\(repository)/releases/tag/\(tag)")
        }

        let pathParts = releasesPageURL.pathComponents.filter { $0 != "/" }
        if pathParts.contains("releases") {
            return releasesPageURL.appendingPathComponent("tag").appendingPathComponent(tag)
        }

        return releasesPageURL
            .appendingPathComponent("releases")
            .appendingPathComponent("tag")
            .appendingPathComponent(tag)
    }

    nonisolated static func current(bundle: Bundle = .main) -> AppUpdateConfiguration? {
        let info = bundle.infoDictionary ?? [:]

        guard
            let releasesURLString = (info["UpdateCheckReleasesURL"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !releasesURLString.isEmpty,
            let releasesPageURL = URL(string: releasesURLString),
            let (owner, repository) = githubOwnerRepository(from: releasesPageURL)
        else {
            return nil
        }

        let appName = (info["CFBundleDisplayName"] as? String) ??
            (info["CFBundleName"] as? String) ??
            "This app"
        let currentVersion = (info["CFBundleShortVersionString"] as? String) ??
            (info["CFBundleVersion"] as? String) ??
            "0"

        return AppUpdateConfiguration(
            appName: appName,
            currentVersion: currentVersion,
            owner: owner,
            repository: repository,
            releasesPageURL: releasesPageURL
        )
    }

    private nonisolated static func githubOwnerRepository(from url: URL) -> (String, String)? {
        guard
            let host = url.host?.lowercased(),
            host.contains("github")
        else {
            return nil
        }

        let pathParts = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
        guard pathParts.count >= 2 else {
            return nil
        }

        let owner = pathParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = pathParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !repository.isEmpty else {
            return nil
        }

        return (owner, repository)
    }
}

private struct GitHubLatestVersionDetails: Sendable {
    let tagName: String
    let releaseNotes: String?
    let releaseURL: URL?
}

/// Lightweight GitHub API client used for update checks.
private struct GitHubTagUpdateChecker: Sendable {
    private struct GitHubTag: Decodable, Sendable {
        let name: String
    }

    private struct GitHubRelease: Decodable, Sendable {
        let tagName: String
        let body: String?
        let htmlURL: String?
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }

    private enum UpdateCheckError: LocalizedError {
        case invalidResponse
        case noVersionsFound

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Received an invalid response from GitHub."
            case .noVersionsFound:
                return "No releases or tags were found for this repository."
            }
        }
    }

    func latestVersionDetails(owner: String, repository: String, userAgent: String) async throws -> GitHubLatestVersionDetails {
        do {
            if let releaseVersion = try await latestFromReleases(owner: owner, repository: repository, userAgent: userAgent) {
                return releaseVersion
            }
        } catch {
            AppUpdateCenter.debugLog("GitHubTagUpdateChecker releases lookup failed: \(error.localizedDescription). Falling back to tags.")
        }

        if let tagVersion = try await latestFromTags(owner: owner, repository: repository, userAgent: userAgent) {
            return tagVersion
        }

        throw UpdateCheckError.noVersionsFound
    }

    private func latestFromReleases(owner: String, repository: String, userAgent: String) async throws -> GitHubLatestVersionDetails? {
        let releasesURL = try makeURL(
            "https://api.github.com/repos/\(owner)/\(repository)/releases",
            queryItems: [URLQueryItem(name: "per_page", value: "100")]
        )

        AppUpdateCenter.debugLog("GitHubTagUpdateChecker releases request url=\(releasesURL.absoluteString)")

        let (data, httpResponse) = try await fetch(url: releasesURL, userAgent: userAgent)
        AppUpdateCenter.debugLog("GitHubTagUpdateChecker releases status=\(httpResponse.statusCode), bytes=\(data.count)")

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        AppUpdateCenter.debugLog("GitHubTagUpdateChecker releases decoded count=\(releases.count)")

        let candidates = releases.filter { !$0.draft }
        guard !candidates.isEmpty else {
            return nil
        }

        let stableCandidates = candidates.filter { !$0.prerelease }
        let pool = stableCandidates.isEmpty ? candidates : stableCandidates

        guard let latest = pool.max(by: {
            VersionStringComparator.isVersion($1.tagName, greaterThan: $0.tagName)
        }) else {
            return nil
        }

        let trimmedNotes = latest.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = (trimmedNotes?.isEmpty == false) ? trimmedNotes : nil
        let releaseURL = latest.htmlURL.flatMap(URL.init(string:))
        return GitHubLatestVersionDetails(tagName: latest.tagName, releaseNotes: notes, releaseURL: releaseURL)
    }

    private func latestFromTags(owner: String, repository: String, userAgent: String) async throws -> GitHubLatestVersionDetails? {
        let tagsURL = try makeURL(
            "https://api.github.com/repos/\(owner)/\(repository)/tags",
            queryItems: [URLQueryItem(name: "per_page", value: "100")]
        )

        AppUpdateCenter.debugLog("GitHubTagUpdateChecker tags request url=\(tagsURL.absoluteString)")

        let (data, httpResponse) = try await fetch(url: tagsURL, userAgent: userAgent)
        AppUpdateCenter.debugLog("GitHubTagUpdateChecker tags status=\(httpResponse.statusCode), bytes=\(data.count)")

        let tags = try JSONDecoder().decode([GitHubTag].self, from: data)
        guard !tags.isEmpty else {
            return nil
        }

        AppUpdateCenter.debugLog("GitHubTagUpdateChecker tags decoded count=\(tags.count)")

        guard let latestTag = tags.max(by: { lhs, rhs in
            VersionStringComparator.isVersion(rhs.name, greaterThan: lhs.name)
        }) else {
            return nil
        }

        return GitHubLatestVersionDetails(tagName: latestTag.name, releaseNotes: nil, releaseURL: nil)
    }

    private func makeURL(_ raw: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: raw) else {
            throw URLError(.badURL)
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func fetch(url: URL, userAgent: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            if let httpResponse = response as? HTTPURLResponse {
                AppUpdateCenter.debugLog("GitHubTagUpdateChecker non-2xx status=\(httpResponse.statusCode) for \(url.absoluteString)")
            } else {
                AppUpdateCenter.debugLog("GitHubTagUpdateChecker invalid non-HTTP response for \(url.absoluteString)")
            }
            throw UpdateCheckError.invalidResponse
        }

        return (data, httpResponse)
    }
}

/// Semantic-ish version comparator that tolerates common GitHub tag formats.
private enum VersionStringComparator {
    nonisolated static func isVersion(_ lhs: String, greaterThan rhs: String) -> Bool {
        let lhsComponents = numericComponents(from: lhs)
        let rhsComponents = numericComponents(from: rhs)
        let maxCount = max(lhsComponents.count, rhsComponents.count)

        for index in 0..<maxCount {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
        }

        // If numeric components are equal, treat versions as equal even when one has a
        // personal/build suffix like ".Home" (e.g., 1.5.0 vs 1.5.0.Home).
        return false
    }

    private nonisolated static func numericComponents(from rawVersion: String) -> [Int] {
        let trimmed = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let noPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let base = noPrefix.split(whereSeparator: { character in
            !(character.isNumber || character == ".")
        }).first ?? Substring("")

        let parts = base.split(separator: ".")
        let numericParts = parts.compactMap { Int($0) }
        if !numericParts.isEmpty {
            return numericParts
        }

        let digitsOnly = noPrefix.filter(\.isNumber)
        if let number = Int(digitsOnly) {
            return [number]
        }

        return [0]
    }
}

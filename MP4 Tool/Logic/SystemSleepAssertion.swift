//
//  SystemSleepAssertion.swift
//  MP4 Tool
//

import Foundation

/// Prevents idle system sleep for the lifetime of the assertion while still
/// allowing the display to sleep normally.
nonisolated final class SystemSleepAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var activity: NSObjectProtocol?

    init(reason: String) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: reason
        )
    }

    func invalidate() {
        lock.lock()
        let activityToEnd = activity
        activity = nil
        lock.unlock()

        if let activityToEnd {
            ProcessInfo.processInfo.endActivity(activityToEnd)
        }
    }

    deinit {
        invalidate()
    }
}

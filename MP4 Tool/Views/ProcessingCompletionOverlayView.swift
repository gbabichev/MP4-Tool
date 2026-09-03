import SwiftUI

struct ProcessingCompletionOverlayView: View {
  let summary: ProcessingCompletionSummary
  let onOpenInFinder: () -> Void
  let onDismiss: () -> Void

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
  }()

  private var isRemux: Bool {
    summary.mode == .remux
  }

  private var actionTitle: String {
    if summary.failedFileCount > 0 || summary.skippedFileCount > 0 {
      return "Processing Complete"
    }
    return isRemux ? "Remux Complete" : "Encoding Complete"
  }

  private var fileMetricTitle: String {
    isRemux ? "Files Remuxed" : "Files Encoded"
  }

  private var savedMetricTitle: String {
    summary.savedBytes < 0 ? "Space Increase" : "Space Saved"
  }

  private var savedMetricValue: String {
    formattedBytes(abs(summary.savedBytes))
  }

  private var savingsDetail: String? {
    guard summary.originalBytes > 0 else { return nil }
    let fraction = Double(abs(summary.savedBytes)) / Double(summary.originalBytes)
    return fraction.formatted(.percent.precision(.fractionLength(1)))
  }

  private var completionMessage: String {
    guard summary.failedFileCount > 0 || summary.skippedFileCount > 0 else {
      return "Your batch finished successfully."
    }
    var results: [String] = []
    if summary.skippedFileCount > 0 {
      results.append("\(summary.skippedFileCount) skipped")
    }
    if summary.failedFileCount > 0 {
      results.append("\(summary.failedFileCount) failed")
    }
    return "Batch finished with \(results.joined(separator: " and "))."
  }

  private var completionCountDetail: String? {
    var results: [String] = []
    if summary.skippedFileCount > 0 {
      results.append("\(summary.skippedFileCount) skipped")
    }
    if summary.failedFileCount > 0 {
      results.append("\(summary.failedFileCount) failed")
    }
    return results.isEmpty ? nil : results.joined(separator: " • ")
  }

  var body: some View {
    ZStack {
      Color.black.opacity(0.3)
        .ignoresSafeArea()

      GeometryReader { geometry in
        let cardWidth = min(600, max(320, geometry.size.width - 80))
        let cardHeight = min(720, max(320, geometry.size.height - 80))

        VStack {
          ZStack(alignment: .topTrailing) {
            ScrollView {
              VStack(spacing: 20) {
            VStack(spacing: 8) {
              Image(
                systemName: summary.failedFileCount > 0 || summary.skippedFileCount > 0
                  ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
              )
                .font(.system(size: 46))
                .foregroundStyle(
                  summary.failedFileCount > 0 || summary.skippedFileCount > 0 ? .orange : .green
                )

              Text(actionTitle)
                .font(.title.weight(.semibold))

              Text(completionMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
              CompletionMetric(
                icon: isRemux ? "arrow.left.arrow.right.circle" : "film.stack",
                title: fileMetricTitle,
                value: "\(summary.completedFileCount)",
                detail: completionCountDetail
              )
              CompletionMetric(
                icon: summary.savedBytes < 0 ? "arrow.up.right" : "arrow.down.right",
                title: savedMetricTitle,
                value: savedMetricValue,
                detail: savingsDetail
              )
              CompletionMetric(
                icon: "clock",
                title: "Total Run Time",
                value: formattedDuration(summary.runTime)
              )
            }

            VStack(alignment: .leading, spacing: 10) {
              Text("Storage")
                .font(.headline)

              CompletionDetailRow(
                title: "Original files",
                value: formattedBytes(summary.originalBytes)
              )
              CompletionDetailRow(
                title: "Output files",
                value: formattedBytes(summary.outputBytes)
              )
              Divider()
              CompletionDetailRow(
                title: savedMetricTitle,
                value: savedMetricValue,
                emphasized: true
              )
            }
            .completionSectionStyle()

            VStack(alignment: .leading, spacing: 10) {
              Text("Timing")
                .font(.headline)

              CompletionDetailRow(
                title: "Started",
                value: Self.dateFormatter.string(from: summary.startedAt)
              )
              CompletionDetailRow(
                title: "Finished",
                value: Self.dateFormatter.string(from: summary.endedAt)
              )
              CompletionDetailRow(
                title: "Total run time",
                value: formattedDuration(summary.runTime),
                emphasized: true
              )
            }
            .completionSectionStyle()

                HStack(spacing: 10) {
                  Button(action: onOpenInFinder) {
                    Label("Open in Finder", systemImage: "folder")
                  }
                  .controlSize(.large)

                  Button("Done") {
                    onDismiss()
                  }
                  .buttonStyle(.borderedProminent)
                  .controlSize(.large)
                  .keyboardShortcut(.defaultAction)
                }
              }
              .padding(24)
              .frame(width: cardWidth)
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(
              RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .overlay(
                  RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .scrollIndicators(.automatic)
            .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 12)

            Button(action: onDismiss) {
              Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(14)
            .accessibilityLabel("Close completion summary")
          }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
    }
    .transition(.opacity)
    .onExitCommand(perform: onDismiss)
  }

  private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private func formattedDuration(_ interval: TimeInterval) -> String {
    let totalSeconds = max(Int(interval.rounded()), 0)
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
      return "\(hours)h \(minutes)m \(seconds)s"
    }
    if minutes > 0 {
      return "\(minutes)m \(seconds)s"
    }
    return "\(seconds)s"
  }
}

private struct CompletionMetric: View {
  let icon: String
  let title: String
  let value: String
  var detail: String?

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.tint)
      Text(value)
        .font(.title3.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      if let detail {
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 100)
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
  }
}

private struct CompletionDetailRow: View {
  let title: String
  let value: String
  var emphasized = false

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .fontWeight(emphasized ? .semibold : .regular)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
    .font(.subheadline)
  }
}

extension View {
  fileprivate func completionSectionStyle() -> some View {
    padding(14)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.secondary.opacity(0.06))
      )
  }
}

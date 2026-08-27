import SwiftUI

struct ToolSelectionRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let emptySystemImage: String
    let selectedSystemImage: String
    let chooseLabel: String
    let openLabel: String
    let chooseDisabled: Bool
    var compactLayout: Bool = false
    let openAction: () -> Void
    let chooseAction: () -> Void

    var body: some View {
        if compactLayout {
            compactContent
        } else {
            regularContent
        }
    }

    private var regularContent: some View {
        HStack(spacing: 12) {
            selectionIcon

            selectionLabels

            Spacer(minLength: 12)

            selectionButtons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                selectionIcon
                selectionLabels
            }

            HStack(spacing: 8) {
                Spacer()
                selectionButtons
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectionIcon: some View {
        Image(systemName: isSelected ? selectedSystemImage : emptySystemImage)
            .font(.title3)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 24)
    }

    private var selectionLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)

            Text(detail)
                .font(.caption)
                .foregroundStyle(isSelected ? .secondary : .tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var selectionButtons: some View {
        Group {
            Button(chooseLabel, action: chooseAction)
                .controlSize(.small)
                .disabled(chooseDisabled)

            Button(openLabel, action: openAction)
                .controlSize(.small)
                .disabled(!isSelected)
        }
    }
}

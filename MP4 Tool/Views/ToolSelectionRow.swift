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
    let openAction: () -> Void
    let chooseAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? selectedSystemImage : emptySystemImage)
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 24)

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

            Spacer(minLength: 12)

            Button(chooseLabel, action: chooseAction)
                .controlSize(.small)
                .disabled(chooseDisabled)

            Button(openLabel, action: openAction)
                .controlSize(.small)
                .disabled(!isSelected)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

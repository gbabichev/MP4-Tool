//
//  SettingsSection.swift
//  Screen Snip
//
//  Created by George Babichev on 9/13/25.
//

import SwiftUI
// MARK: - Reusable building blocks

struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let isModified: Bool
    @ViewBuilder var control: Control

    init(
        _ title: String,
        subtitle: String? = nil,
        isModified: Bool = false,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isModified = isModified
        self.control = control()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            stackedLayout
        }
    }

    private var horizontalLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                titleView
                Spacer(minLength: 16)
                styledControl
            }
            .frame(minHeight: 35)

            subtitleText
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleView

            styledControl
                .frame(maxWidth: .infinity, alignment: .trailing)

            subtitleText
        }
    }

    private var styledControl: some View {
        control
            .labelsHidden()
            .controlSize(.small)
    }

    private var titleView: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fixedSize(horizontal: true, vertical: false)

            if isModified {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

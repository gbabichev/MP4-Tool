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
    @ViewBuilder var control: Control

    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text(title)
                Spacer(minLength: 16)
                control
                    .labelsHidden()
                    .controlSize(.large)
            }
            .frame(minHeight: 35)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

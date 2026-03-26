//
//  GoogleChromeProfilePicker.swift
//
//  Created by Codex on 26/03/2026.
//

import SwiftUI

struct GoogleChromeProfilePicker: View {
    let profiles: [BrowserProfile]
    let onSelect: (BrowserProfile) -> ()
    let onCancel: () -> ()

    @State private var selectedProfileDirectory: String?

    init(
        profiles: [BrowserProfile],
        onSelect: @escaping (BrowserProfile) -> (),
        onCancel: @escaping () -> ()
    ) {
        self.profiles = profiles
        self.onSelect = onSelect
        self.onCancel = onCancel
        _selectedProfileDirectory = State(initialValue: profiles.first?.directory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12.0) {
            Text("Choose Google Chrome Profile")
                .font(.headline)

            List(profiles, id: \.directory, selection: $selectedProfileDirectory) { profile in
                VStack(alignment: .leading, spacing: 2.0) {
                    Text(profile.name)

                    if let email = profile.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(profile.directory)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .tag(profile.directory)
            }
            .frame(height: 220)

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)

                Button("Add") {
                    guard let selectedProfile else { return }
                    onSelect(selectedProfile)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedProfile == nil)
            }
        }
        .padding()
        .frame(width: 360, height: 320)
    }

    private var selectedProfile: BrowserProfile? {
        profiles.first { $0.directory == selectedProfileDirectory }
    }
}

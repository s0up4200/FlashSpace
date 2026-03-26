//
//  MacApp.swift
//
//  Created by Wojciech Kulik on 06/02/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit

typealias BundleId = String

struct BrowserProfile: Codable, Hashable {
    let directory: String
    let name: String
    let email: String?
}

struct MacApp: Codable, Hashable, Equatable {
    var name: String
    var bundleIdentifier: BundleId
    var iconPath: String?
    var autoOpen: Bool?
    var browserProfile: BrowserProfile?

    init(
        name: String,
        bundleIdentifier: BundleId,
        iconPath: String?,
        autoOpen: Bool?,
        browserProfile: BrowserProfile? = nil
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.iconPath = iconPath
        self.autoOpen = autoOpen
        self.browserProfile = browserProfile
    }

    init(app: NSRunningApplication) {
        self.name = app.localizedName ?? ""
        self.bundleIdentifier = app.bundleIdentifier ?? ""
        self.iconPath = app.iconPath
        self.browserProfile = nil
    }

    init(from decoder: any Decoder) throws {
        if let app = try? decoder.singleValueContainer().decode(String.self) {
            // V1 - migration
            let runningApp = NSWorkspace.shared.runningApplications
                .first { $0.localizedName == app }

            self.name = app

            if let runningApp {
                self.bundleIdentifier = runningApp.bundleIdentifier ?? ""
                self.iconPath = runningApp.iconPath
            } else if let bundle = Bundle(path: "/Applications/\(app).app") {
                self.bundleIdentifier = bundle.bundleIdentifier ?? ""
                self.iconPath = bundle.iconPath
            } else if let bundle = Bundle(path: "/System/Applications/\(app).app") {
                self.bundleIdentifier = bundle.bundleIdentifier ?? ""
                self.iconPath = bundle.iconPath
            } else {
                self.bundleIdentifier = ""
                self.iconPath = nil
            }

            Migrations.appsMigrated = true
        } else {
            // V2
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            self.bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
            self.iconPath = try container.decodeIfPresent(String.self, forKey: .iconPath)
            self.autoOpen = try container.decodeIfPresent(Bool.self, forKey: .autoOpen)
            self.browserProfile = try container.decodeIfPresent(BrowserProfile.self, forKey: .browserProfile)
        }
    }

    func hash(into hasher: inout Hasher) {
        if bundleIdentifier.isEmpty {
            hasher.combine(name)
        } else {
            hasher.combine(bundleIdentifier)
            hasher.combine(browserProfile?.directory)
        }
    }

    static func == (lhs: MacApp, rhs: MacApp) -> Bool {
        if lhs.bundleIdentifier.isEmpty || rhs.bundleIdentifier.isEmpty {
            return lhs.name == rhs.name
        } else {
            return lhs.bundleIdentifier == rhs.bundleIdentifier &&
                lhs.browserProfile?.directory == rhs.browserProfile?.directory
        }
    }
}

extension MacApp {
    var displayName: String {
        guard let browserProfile else { return name }
        return "\(name) - \(browserProfile.name)"
    }

    var detailText: String? {
        browserProfile?.email
    }

    var isFinder: Bool {
        bundleIdentifier == "com.apple.finder"
    }

    var isGoogleChrome: Bool {
        bundleIdentifier == "com.google.Chrome"
    }

    var isProfileAwareBrowser: Bool {
        isGoogleChrome && browserProfile != nil
    }

    var launchArguments: [String] {
        guard isGoogleChrome, let browserProfile else { return [] }
        return ["--profile-directory=\(browserProfile.directory)"]
    }
}

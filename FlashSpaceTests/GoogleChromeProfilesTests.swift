import AppKit
@testable import FlashSpace_Dev
import XCTest

final class GoogleChromeProfilesTests: XCTestCase {
    func testParseProfilesFromLocalState() throws {
        let data = Data("""
        {
          "profile": {
            "info_cache": {
              "Profile 2": {
                "name": "Work",
                "user_name": "work@example.com"
              },
              "Default": {
                "name": "Personal",
                "user_name": "personal@example.com"
              }
            }
          }
        }
        """.utf8)

        let profiles = try GoogleChromeProfileCatalog.parse(data: data)

        XCTAssertEqual(
            profiles,
            [
                BrowserProfile(directory: "Default", name: "Personal", email: "personal@example.com"),
                BrowserProfile(directory: "Profile 2", name: "Work", email: "work@example.com")
            ]
        )
    }

    func testChromeLaunchArgumentsIncludeProfileDirectory() {
        let app = MacApp(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            iconPath: nil,
            autoOpen: true,
            browserProfile: BrowserProfile(directory: "Profile 2", name: "Work", email: nil)
        )

        XCTAssertEqual(app.launchArguments, ["--profile-directory=Profile 2"])
    }

    func testChromeDisplayNameIncludesProfileName() {
        let app = MacApp(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            iconPath: nil,
            autoOpen: true,
            browserProfile: BrowserProfile(directory: "Profile 2", name: "Work", email: nil)
        )

        XCTAssertEqual(app.displayName, "Google Chrome - Work")
    }

    func testAppIdentityDistinguishesChromeProfiles() {
        let work = MacApp(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            iconPath: nil,
            autoOpen: nil,
            browserProfile: BrowserProfile(directory: "Profile 2", name: "Work", email: nil)
        )
        let personal = MacApp(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            iconPath: nil,
            autoOpen: nil,
            browserProfile: BrowserProfile(directory: "Default", name: "Personal", email: nil)
        )

        XCTAssertNotEqual(work, personal)
    }

    func testProfileAwareWindowAssignmentsRememberWindowPerWorkspaceAndApp() {
        let workspaceId = WorkspaceID()
        let app = MacApp(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            iconPath: nil,
            autoOpen: nil,
            browserProfile: BrowserProfile(directory: "Profile 2", name: "Work", email: nil)
        )
        var assignments = ProfileAwareWindowAssignments()
        let window = AXUIElementCreateSystemWide()

        assignments.remember(windowId: 42, window: window, for: app, in: workspaceId)

        XCTAssertEqual(assignments.windowId(for: app, in: workspaceId), 42)
    }

    func testProfileAwareWindowAssignmentsRememberWindowReferencePerWorkspaceAndApp() {
        let workspaceId = WorkspaceID()
        let app = MacApp(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            iconPath: nil,
            autoOpen: nil,
            browserProfile: BrowserProfile(directory: "Profile 2", name: "Work", email: nil)
        )
        let window = AXUIElementCreateSystemWide()
        var assignments = ProfileAwareWindowAssignments()

        assignments.remember(windowId: 42, window: window, for: app, in: workspaceId)

        XCTAssertNotNil(assignments.window(for: app, in: workspaceId))
    }

    func testProfileAwareWindowAssignmentsFindWorkspaceByWindowIdUsingPriorityOrder() {
        let workWorkspaceId = WorkspaceID()
        let personalWorkspaceId = WorkspaceID()
        let app = MacApp(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            iconPath: nil,
            autoOpen: nil,
            browserProfile: BrowserProfile(directory: "Profile 2", name: "Work", email: nil)
        )
        let workWorkspace = Workspace(
            id: workWorkspaceId,
            name: "Work",
            display: "Main",
            activateShortcut: nil,
            assignAppShortcut: nil,
            apps: [app]
        )
        let personalWorkspace = Workspace(
            id: personalWorkspaceId,
            name: "Personal",
            display: "Main",
            activateShortcut: nil,
            assignAppShortcut: nil,
            apps: [app]
        )
        var assignments = ProfileAwareWindowAssignments()
        let personalWindow = AXUIElementCreateSystemWide()
        let workWindow = AXUIElementCreateSystemWide()

        assignments.remember(windowId: 100, window: personalWindow, for: app, in: personalWorkspaceId)
        assignments.remember(windowId: 200, window: workWindow, for: app, in: workWorkspaceId)

        XCTAssertEqual(
            assignments.workspaceId(
                for: 200,
                prioritizedWorkspaces: [workWorkspace, personalWorkspace]
            ),
            workWorkspaceId
        )
    }

    func testProfileAwareWorkspaceFocusPlanDoesNotReactivateSameAppAfterWindowFocus() {
        let plan = ProfileAwareWorkspaceFocusPlan(
            appToFocusBundleIdentifier: "com.google.Chrome",
            profileAwareWindowAppBundleIdentifier: "com.google.Chrome"
        )

        XCTAssertTrue(plan.shouldFocusProfileAwareWindow)
        XCTAssertFalse(plan.shouldActivateAppBeforeWindowFocus)
        XCTAssertFalse(plan.shouldActivateAppAfterWindowFocus)
    }

    func testProfileAwareWorkspaceFocusPlanActivatesAppBeforeWindowFocusWhenNoAppTargetExists() {
        let plan = ProfileAwareWorkspaceFocusPlan(
            appToFocusBundleIdentifier: nil,
            profileAwareWindowAppBundleIdentifier: "com.google.Chrome"
        )

        XCTAssertTrue(plan.shouldFocusProfileAwareWindow)
        XCTAssertTrue(plan.shouldActivateAppBeforeWindowFocus)
        XCTAssertFalse(plan.shouldActivateAppAfterWindowFocus)
    }

    func testProfileAwareWorkspaceFocusPlanKeepsAppActivationForDifferentApp() {
        let plan = ProfileAwareWorkspaceFocusPlan(
            appToFocusBundleIdentifier: "com.apple.finder",
            profileAwareWindowAppBundleIdentifier: "com.google.Chrome"
        )

        XCTAssertFalse(plan.shouldFocusProfileAwareWindow)
        XCTAssertFalse(plan.shouldActivateAppBeforeWindowFocus)
        XCTAssertTrue(plan.shouldActivateAppAfterWindowFocus)
    }

    func testProfileAwareWorkspaceFocusPlanPrefersProfileWindowOverFinderFallback() {
        let plan = ProfileAwareWorkspaceFocusPlan(
            appToFocusBundleIdentifier: "com.apple.finder",
            profileAwareWindowAppBundleIdentifier: "com.google.Chrome",
            appToFocusIsFinderFallback: true
        )

        XCTAssertTrue(plan.shouldFocusProfileAwareWindow)
        XCTAssertTrue(plan.shouldActivateAppBeforeWindowFocus)
        XCTAssertFalse(plan.shouldActivateAppAfterWindowFocus)
    }
}

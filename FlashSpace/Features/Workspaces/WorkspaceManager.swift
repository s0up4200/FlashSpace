//
//  WorkspaceManager.swift
//
//  Created by Wojciech Kulik on 19/01/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//
// swiftlint:disable file_length

import AppKit
import Combine

typealias DisplayName = String

struct ActiveWorkspace {
    let id: WorkspaceID
    let name: String
    let number: String?
    let symbolIconName: String?
    let display: DisplayName
}

struct ProfileAwareWorkspaceFocusPlan {
    let shouldFocusProfileAwareWindow: Bool
    let shouldActivateAppBeforeWindowFocus: Bool
    let shouldActivateAppAfterWindowFocus: Bool

    init(
        appToFocusBundleIdentifier: BundleId?,
        profileAwareWindowAppBundleIdentifier: BundleId?,
        appToFocusIsFinderFallback: Bool = false
    ) {
        let hasProfileAwareWindow = profileAwareWindowAppBundleIdentifier != nil
        let appMatchesProfileAwareWindow = appToFocusBundleIdentifier == profileAwareWindowAppBundleIdentifier

        shouldFocusProfileAwareWindow = hasProfileAwareWindow &&
            (appToFocusBundleIdentifier == nil || appMatchesProfileAwareWindow || appToFocusIsFinderFallback)
        shouldActivateAppBeforeWindowFocus = shouldFocusProfileAwareWindow &&
            (appToFocusBundleIdentifier == nil || appToFocusIsFinderFallback)
        shouldActivateAppAfterWindowFocus = if appToFocusBundleIdentifier == nil {
            false
        } else if !hasProfileAwareWindow {
            true
        } else {
            !appMatchesProfileAwareWindow && !appToFocusIsFinderFallback
        }
    }
}

private struct WorkspaceAppFocusSelection {
    let app: NSRunningApplication?
    let isFinderFallback: Bool
}

// swiftlint:disable:next type_body_length
final class WorkspaceManager: ObservableObject {
    @Published private(set) var activeWorkspaceDetails: ActiveWorkspace?

    private(set) var lastFocusedApp: [ProfileId: [WorkspaceID: MacApp]] = [:]
    private(set) var activeWorkspace: [DisplayName: Workspace] = [:]
    private(set) var mostRecentWorkspace: [DisplayName: Workspace] = [:]
    private(set) var lastWorkspaceActivation = Date.distantPast
    private(set) var workspaceActivationTimes: [WorkspaceID: Date] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var observeFocusCancellable: AnyCancellable?
    private var appsHiddenManually: [WorkspaceID: [MacApp]] = [:]
    private var profileAwareWindowAssignments = ProfileAwareWindowAssignments()
    private var recentAppOpenTimes: [MacApp: Date] = [:]
    private let hideAgainSubject = PassthroughSubject<Workspace, Never>()

    private lazy var focusedWindowTracker = AppDependencies.shared.focusedWindowTracker

    private let workspaceRepository: WorkspaceRepository
    private let workspaceSettings: WorkspaceSettings
    private let profilesRepository: ProfilesRepository
    private let floatingAppsSettings: FloatingAppsSettings
    private let pictureInPictureManager: PictureInPictureManager
    private let workspaceTransitionManager: WorkspaceTransitionManager
    private let displayManager: DisplayManager

    init(
        workspaceRepository: WorkspaceRepository,
        settingsRepository: SettingsRepository,
        profilesRepository: ProfilesRepository,
        pictureInPictureManager: PictureInPictureManager,
        workspaceTransitionManager: WorkspaceTransitionManager,
        displayManager: DisplayManager
    ) {
        self.workspaceRepository = workspaceRepository
        self.profilesRepository = profilesRepository
        self.workspaceSettings = settingsRepository.workspaceSettings
        self.floatingAppsSettings = settingsRepository.floatingAppsSettings
        self.pictureInPictureManager = pictureInPictureManager
        self.workspaceTransitionManager = workspaceTransitionManager
        self.displayManager = displayManager

        PermissionsManager.shared.askForAccessibilityPermissions()
        observe()
    }

    private func observe() {
        hideAgainSubject
            .debounce(for: 0.2, scheduler: RunLoop.main)
            .sink { [weak self] in self?.hideApps(in: $0) }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .profileChanged)
            .sink { [weak self] _ in self?.resetActiveWorkspaceState() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.resetActiveWorkspaceState() }
            .store(in: &cancellables)

        workspaceRepository.workspacesPublisher
            .sink { [weak self] workspaces in
                self?.updateWorkspaces(workspaces)
            }
            .store(in: &cancellables)

        observeFocus()
    }

    private func resetActiveWorkspaceState() {
        activeWorkspace = [:]
        mostRecentWorkspace = [:]
        activeWorkspaceDetails = nil
    }

    private func observeFocus() {
        observeFocusCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.activationPolicy == .regular }
            .sink { [weak self] application in
                self?.invalidateInactiveWorkspaces()
                self?.rememberLastFocusedApp(application, retry: true)
            }
    }

    private func rememberLastFocusedApp(_ application: NSRunningApplication, retry: Bool) {
        guard application.display != nil else {
            if retry {
                Logger.log("Retrying to get display for \(application.localizedName ?? "")")
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if let frontmostApp = NSWorkspace.shared.frontmostApplication {
                        self.rememberLastFocusedApp(frontmostApp, retry: false)
                    }
                }
            } else {
                return Logger.log("Unable to get display for \(application.localizedName ?? "")")
            }
        }

        let focusedDisplay = DisplayName.current

        if let activeWorkspace = activeWorkspace[focusedDisplay] {
            if rememberFocusedProfileAwareWindow(application, in: activeWorkspace) {
                updateActiveWorkspace(activeWorkspace, on: [focusedDisplay])
            } else if activeWorkspace.apps.containsApp(application) {
                updateLastFocusedApp(application.toMacApp, in: activeWorkspace)
                updateActiveWorkspace(activeWorkspace, on: [focusedDisplay])
            }
        }

        displayManager.trackDisplayFocus(on: focusedDisplay, for: application)
    }

    private func updateWorkspaces(_ workspaces: [Workspace]) {
        let updatedWorkspaces = workspaces.reduce(into: [WorkspaceID: Workspace]()) { $0[$1.id] = $1 }

        for (display, workspace) in activeWorkspace {
            activeWorkspace[display] = updatedWorkspaces[workspace.id]
        }

        for (display, workspace) in mostRecentWorkspace {
            mostRecentWorkspace[display] = updatedWorkspaces[workspace.id]
        }
    }

    private func showApps(in workspace: Workspace, setFocus: Bool, on displays: Set<DisplayName>) {
        let regularApps = NSWorkspace.shared.runningRegularApps
        let floatingApps = floatingAppsSettings.floatingApps
        let hiddenApps = appsHiddenManually[workspace.id] ?? []
        let profileAwareBundleIds = workspaceRepository.workspaces
            .flatMap(\.profileAwareApps)
            .map(\.bundleIdentifier)
            .asSet
        var appsToShow = regularApps
            .filter { !hiddenApps.containsApp($0) }
            .filter {
                !profileAwareBundleIds.contains($0.bundleIdentifier ?? "") &&
                    (workspace.apps.containsApp($0) ||
                        floatingApps.containsApp($0) && $0.isOnAnyDisplay(displays)
                    )
            }

        observeFocusCancellable = nil
        defer { observeFocus() }

        let profileAwareWindowToFocus = focusedProfileAwareWindow(in: workspace)

        if setFocus {
            let focusSelection = findAppToFocus(in: workspace, apps: appsToShow)
            let toFocus = focusSelection.app

            moveFocusedAppToEnd(of: &appsToShow, appToFocus: toFocus)
            showRegularApps(appsToShow, appToFocus: toFocus)

            let focusedFrame = focusWorkspaceSelection(
                workspace,
                appToFocus: toFocus,
                focusSelection: focusSelection,
                profileAwareWindowToFocus: profileAwareWindowToFocus
            )

            centerCursorIfNeeded(in: focusedFrame ?? toFocus?.frame)
        } else {
            for app in appsToShow {
                Logger.log("SHOW: \(app.localizedName ?? "")")
                app.raise()
            }

            restoreProfileAwareWindows(in: workspace, focusWindow: false)
        }
    }

    private func moveFocusedAppToEnd(of appsToShow: inout [NSRunningApplication], appToFocus: NSRunningApplication?) {
        guard let appToFocus else { return }

        appsToShow.removeAll { $0 == appToFocus }
        appsToShow.append(appToFocus)
    }

    private func showRegularApps(_ appsToShow: [NSRunningApplication], appToFocus: NSRunningApplication?) {
        for app in appsToShow {
            Logger.log("SHOW: \(app.localizedName ?? "")")

            if app == appToFocus || app.isHidden || app.isMinimized {
                app.raise()
            }

            pictureInPictureManager.showPipAppIfNeeded(app: app)
            pictureInPictureManager.showCornerHiddenAppIfNeeded(app: app)
        }
    }

    private func focusWorkspaceSelection(
        _ workspace: Workspace,
        appToFocus: NSRunningApplication?,
        focusSelection: WorkspaceAppFocusSelection,
        profileAwareWindowToFocus: (app: NSRunningApplication, window: AXUIElement)?
    ) -> CGRect? {
        Logger.log("FOCUS: \(appToFocus?.localizedName ?? "")")

        let focusPlan = ProfileAwareWorkspaceFocusPlan(
            appToFocusBundleIdentifier: appToFocus?.bundleIdentifier,
            profileAwareWindowAppBundleIdentifier: profileAwareWindowToFocus?.app.bundleIdentifier,
            appToFocusIsFinderFallback: focusSelection.isFinderFallback
        )

        let focusedProfileAwareFrame: CGRect?
        if focusPlan.shouldFocusProfileAwareWindow {
            focusedProfileAwareFrame = focusProfileAwareWindowIfNeeded(
                profileAwareWindowToFocus,
                activateApp: focusPlan.shouldActivateAppBeforeWindowFocus
            )
        } else {
            restoreProfileAwareWindows(in: workspace, focusWindow: false)
            focusedProfileAwareFrame = nil
        }

        if focusPlan.shouldActivateAppAfterWindowFocus {
            appToFocus?.activate()
        }

        return focusedProfileAwareFrame
    }

    private func hideApps(in workspace: Workspace) {
        let regularApps = NSWorkspace.shared.runningRegularApps
        let workspaceApps = workspace.apps + floatingAppsSettings.floatingApps
        let profileAwareBundleIds = workspaceRepository.workspaces
            .flatMap(\.profileAwareApps)
            .map(\.bundleIdentifier)
            .asSet
        let isAnyWorkspaceAppRunning = regularApps
            .contains { workspaceApps.containsApp($0) }
        let allAssignedApps = workspaceRepository.workspaces
            .flatMap(\.apps)
            .map(\.bundleIdentifier)
            .asSet
        let displays = workspace.displays

        let appsToHide = regularApps
            .filter {
                !$0.isHidden &&
                    !profileAwareBundleIds.contains($0.bundleIdentifier ?? "") &&
                    !workspaceApps.containsApp($0) &&
                    (!workspaceSettings.keepUnassignedAppsOnSwitch || allAssignedApps.contains($0.bundleIdentifier ?? ""))
            }
            .filter { isAnyWorkspaceAppRunning || $0.bundleURL?.fileName != "Finder" }
            .filter { $0.isOnAnyDisplay(displays) }

        for app in appsToHide {
            Logger.log("HIDE: \(app.localizedName ?? "")")

            if !pictureInPictureManager.hideCornerHiddenAppIfNeeded(app: app),
               !pictureInPictureManager.hidePipAppIfNeeded(app: app) {
                app.hide()
            }
        }

        minimizeProfileAwareWindows(excluding: workspace, on: displays)
    }

    private func findAppToFocus(
        in workspace: Workspace,
        apps: [NSRunningApplication]
    ) -> WorkspaceAppFocusSelection {
        if workspace.appToFocus == nil {
            let displays = workspace.displays
            if let floatingEntry = displayManager.lastFocusedDisplay(where: {
                let isFloating = floatingAppsSettings.floatingApps.contains($0.app)
                let isUnassigned = workspaceSettings.keepUnassignedAppsOnSwitch &&
                    !workspaceRepository.workspaces.flatMap(\.apps).contains($0.app)
                return (isFloating || isUnassigned) && displays.contains($0.display)
            }),
                let runningApp = NSWorkspace.shared.runningApplications.find(floatingEntry.app) {
                return .init(app: runningApp, isFinderFallback: false)
            }
        }

        var appToFocus: NSRunningApplication?

        if workspace.appToFocus == nil {
            appToFocus = apps.find(lastFocusedApp[profilesRepository.selectedProfile.id, default: [:]][workspace.id])
        } else {
            appToFocus = apps.find(workspace.appToFocus)
        }

        let fallbackToLastApp = apps.findFirstMatch(with: workspace.apps.reversed())
        let fallbackToFinder = NSWorkspace.shared.runningApplications.first(where: \.isFinder)

        if let appToFocus {
            return .init(app: appToFocus, isFinderFallback: false)
        }

        if let fallbackToLastApp {
            return .init(app: fallbackToLastApp, isFinderFallback: false)
        }

        return .init(app: fallbackToFinder, isFinderFallback: fallbackToFinder != nil)
    }

    private func centerCursorIfNeeded(in frame: CGRect?) {
        guard workspaceSettings.centerCursorOnWorkspaceChange, let frame else { return }

        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func updateActiveWorkspace(_ workspace: Workspace, on displays: Set<DisplayName>) {
        lastWorkspaceActivation = Date()

        // Save the most recent workspace if it's not the current one
        for display in displays {
            if activeWorkspace[display]?.id != workspace.id {
                mostRecentWorkspace[display] = activeWorkspace[display]
            }
            activeWorkspace[display] = workspace
        }

        activeWorkspaceDetails = .init(
            id: workspace.id,
            name: workspace.name,
            number: workspaceRepository.workspaces
                .firstIndex { $0.id == workspace.id }
                .map { "\($0 + 1)" },
            symbolIconName: workspace.symbolIconName,
            display: workspace.displayForPrint
        )

        Integrations.runOnActivateIfNeeded(workspace: activeWorkspaceDetails!)
    }

    private func updateLastActivationTime(for workspace: Workspace) {
        workspaceActivationTimes[workspace.id] = Date()
    }

    private func openAppsIfNeeded(in workspace: Workspace) {
        guard workspace.openAppsOnActivation == true else { return }

        let runningBundleIds = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .asSet

        workspace.apps
            .filter {
                shouldOpen($0, runningBundleIds: runningBundleIds)
            }
            .forEach { app in
                guard let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else {
                    return
                }

                Logger.log("Open App: \(appUrl) \(app.launchArguments.joined(separator: " "))")

                let config = NSWorkspace.OpenConfiguration()
                config.arguments = app.launchArguments
                recentAppOpenTimes[app] = Date()

                NSWorkspace.shared.openApplication(at: appUrl, configuration: config) { _, error in
                    if let error {
                        Logger.log("Failed to open \(appUrl): \(error.localizedDescription)")
                        self.recentAppOpenTimes.removeValue(forKey: app)
                    }
                }
            }
    }

    private func shouldOpen(_ app: MacApp, runningBundleIds: Set<BundleId>) -> Bool {
        guard app.autoOpen == true, app.bundleIdentifier.isNotEmpty else { return false }

        if let recentOpenTime = recentAppOpenTimes[app],
           Date().timeIntervalSince(recentOpenTime) < 2.0 {
            return false
        }

        if app.isGoogleChrome, app.browserProfile != nil {
            // Chrome profile windows are not runtime-classified yet,
            // so we reopen the target profile on activation.
            return true
        }

        return !runningBundleIds.contains(app.bundleIdentifier)
    }

    private func rememberHiddenApps(workspaceToActivate: WorkspaceID?) {
        guard !workspaceSettings.restoreHiddenAppsOnSwitch else {
            appsHiddenManually = [:]
            return
        }

        let hiddenApps = NSWorkspace.shared.runningRegularApps
            .filter { $0.isHidden || $0.isMinimized }

        for activeWorkspace in activeWorkspace.values {
            guard activeWorkspace.id != workspaceToActivate else { continue }

            appsHiddenManually[activeWorkspace.id] = []
        }

        for (display, activeWorkspace) in activeWorkspace {
            guard activeWorkspace.id != workspaceToActivate else { continue }

            let activeWorkspaceOtherDisplays = activeWorkspace.displays.subtracting([display])
            appsHiddenManually[activeWorkspace.id, default: []] += hiddenApps
                .filter {
                    activeWorkspace.apps.containsApp($0) &&
                        $0.isOnAnyDisplay([display]) && !$0.isOnAnyDisplay(activeWorkspaceOtherDisplays)
                }
                .map(\.toMacApp)
        }
    }

    private func deactivateActiveWorkspace(on display: DisplayName) {
        workspaceTransitionManager.showTransitionIfNeeded(for: nil, on: [display])
        rememberHiddenApps(workspaceToActivate: nil)

        if let activeWorkspace = activeWorkspace[display] {
            mostRecentWorkspace[display] = activeWorkspace
        }

        lastWorkspaceActivation = Date()
        activeWorkspaceDetails = nil
        activeWorkspace.removeValue(forKey: display)
    }

    @discardableResult
    func rememberFocusedProfileAwareWindow(
        _ application: NSRunningApplication,
        in workspace: Workspace? = nil
    ) -> Bool {
        let targetWorkspace = workspace ?? activeWorkspace[DisplayName.current]

        guard let targetWorkspace,
              let appTarget = targetWorkspace.profileAwareApp(with: application.bundleIdentifier),
              rememberProfileAwareWindow(for: application, target: appTarget, in: targetWorkspace) else {
            return false
        }

        updateLastFocusedApp(appTarget, in: targetWorkspace)
        return true
    }

    private func rememberProfileAwareWindow(
        for application: NSRunningApplication,
        target appTarget: MacApp,
        in workspace: Workspace
    ) -> Bool {
        guard let window = application.focusedWindow,
              let windowId = window.cgWindowId else { return false }

        profileAwareWindowAssignments.remember(windowId: windowId, window: window, for: appTarget, in: workspace.id)
        return true
    }

    private func focusedProfileAwareWindow(in workspace: Workspace) -> (app: NSRunningApplication, window: AXUIElement)? {
        for appTarget in workspace.profileAwareApps {
            guard let runningApp = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == appTarget.bundleIdentifier }) else {
                continue
            }

            if let window = profileAwareWindowAssignments.window(for: appTarget, in: workspace.id) {
                return (runningApp, window)
            }

            guard let windowId = profileAwareWindowAssignments.windowId(for: appTarget, in: workspace.id),
                  let window = runningApp.allWindows
                  .map(\.window)
                  .first(where: { $0.cgWindowId == windowId }) else {
                continue
            }

            return (runningApp, window)
        }

        return nil
    }

    @discardableResult
    private func focusProfileAwareWindowIfNeeded(
        _ entry: (app: NSRunningApplication, window: AXUIElement)?,
        activateApp: Bool
    ) -> CGRect? {
        guard let entry else { return nil }

        entry.app.unhide()
        entry.window.minimize(false)
        if activateApp {
            entry.app.activate()
        }
        entry.window.focus()

        return entry.window.frame
    }

    private func restoreProfileAwareWindows(in workspace: Workspace, focusWindow: Bool) {
        guard let entry = focusedProfileAwareWindow(in: workspace) else { return }

        entry.app.unhide()
        entry.window.minimize(false)

        if focusWindow {
            entry.app.activate()
            entry.window.focus()
        }
    }

    private func minimizeProfileAwareWindows(excluding workspace: Workspace, on displays: Set<DisplayName>) {
        let protectedWindowIds = profileAwareWindowAssignments.windowIds(in: workspace.id)

        for otherWorkspace in workspaceRepository.workspaces where otherWorkspace.id != workspace.id {
            let windowIds = profileAwareWindowAssignments.windowIds(in: otherWorkspace.id)
                .subtracting(protectedWindowIds)

            guard windowIds.isNotEmpty else { continue }

            for appTarget in otherWorkspace.profileAwareApps {
                guard let runningApp = NSWorkspace.shared.runningApplications
                    .first(where: { $0.bundleIdentifier == appTarget.bundleIdentifier }) else {
                    continue
                }

                for window in runningApp.allWindows.map(\.window)
                    where windowIds.contains(window.cgWindowId ?? 0) &&
                    window.frame?.getDisplay().flatMap(displays.contains) == true {
                    window.minimize(true)
                }
            }
        }
    }

    func workspaceForProfileAwareWindow(_ application: NSRunningApplication, prioritizedWorkspaces: [Workspace]) -> Workspace? {
        guard let windowId = application.focusedWindow?.cgWindowId,
              let workspaceId = profileAwareWindowAssignments.workspaceId(
                  for: windowId,
                  prioritizedWorkspaces: prioritizedWorkspaces
              ) else {
            return nil
        }

        return workspaceRepository.findWorkspace(with: workspaceId)
    }
}

// MARK: - Workspace Actions
extension WorkspaceManager {
    func activateWorkspace(_ workspace: Workspace, setFocus: Bool) {
        guard !workspaceSettings.isPaused else {
            Logger.log("Workspace management is paused - skipping activation")
            return
        }

        let displays = workspace.displays

        Logger.log("")
        Logger.log("")
        Logger.log("WORKSPACE: \(workspace.name)")
        Logger.log("DISPLAYS: \(displays.joined(separator: ", "))")
        Logger.log("----")
        SpaceControl.hide()

        if workspace.isDynamic, workspace.displays.isEmpty,
           workspace.apps.isNotEmpty, workspace.openAppsOnActivation == true {
            Logger.log("No running apps in the workspace - launching apps")
            openAppsIfNeeded(in: workspace)

            if !workspaceSettings.activeWorkspaceOnFocusChange {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.activateWorkspace(workspace, setFocus: setFocus)
                }
            }
            return
        }

        guard displays.isNotEmpty else {
            Logger.log("No displays found for workspace: \(workspace.name) - skipping")
            return
        }

        focusedWindowTracker.stopTracking()
        defer { focusedWindowTracker.startTracking() }

        workspaceTransitionManager.showTransitionIfNeeded(for: workspace, on: displays)

        rememberHiddenApps(workspaceToActivate: workspace.id)
        updateLastActivationTime(for: workspace)
        updateActiveWorkspace(workspace, on: displays)
        openAppsIfNeeded(in: workspace)
        showApps(in: workspace, setFocus: setFocus, on: displays)
        hideApps(in: workspace)
        runIntegrationAfterActivation(for: workspace)

        // Some apps may not hide properly,
        // so we hide apps in the workspace after a short delay
        hideAgainSubject.send(workspace)
    }

    private func runIntegrationAfterActivation(for workspace: Workspace) {
        let newWorkspace = ActiveWorkspace(
            id: workspace.id,
            name: workspace.name,
            number: workspaceRepository.workspaces
                .firstIndex { $0.id == workspace.id }
                .map { "\($0 + 1)" },
            symbolIconName: workspace.symbolIconName,
            display: workspace.displayForPrint
        )

        Integrations.runAfterActivationIfNeeded(workspace: newWorkspace)
    }

    func assignApps(_ apps: [MacApp], to workspace: Workspace) {
        for app in apps {
            workspaceRepository.deleteAppFromAllWorkspaces(app: app)
            workspaceRepository.addApp(to: workspace.id, app: app)
        }

        NotificationCenter.default.post(name: .appsListChanged, object: nil)
    }

    func assignApp(_ app: MacApp, to workspace: Workspace) {
        workspaceRepository.deleteAppFromAllWorkspaces(app: app)
        workspaceRepository.addApp(to: workspace.id, app: app)

        guard let targetWorkspace = workspaceRepository.findWorkspace(with: workspace.id) else { return }

        let isTargetWorkspaceActive = activeWorkspace.values
            .contains(where: { $0.id == workspace.id })

        updateLastFocusedApp(app, in: targetWorkspace)

        if workspaceSettings.changeWorkspaceOnAppAssign {
            activateWorkspace(targetWorkspace, setFocus: true)
        } else if !isTargetWorkspaceActive {
            NSWorkspace.shared.runningApplications
                .find(app)?
                .hide()
            AppDependencies.shared.focusManager.nextWorkspaceApp()
        }

        NotificationCenter.default.post(name: .appsListChanged, object: nil)
    }

    func hideAll() {
        guard let display = DisplayName.currentOptional else { return }

        focusedWindowTracker.stopTracking()
        defer { focusedWindowTracker.startTracking() }

        deactivateActiveWorkspace(on: display)

        let appsToHide = NSWorkspace.shared.runningApplications
            .regularVisibleApps(onDisplays: [display], excluding: [])
            .filter { !$0.isFinder }

        for app in appsToHide {
            Logger.log("CLEAN UP: \(app.localizedName ?? "")")
            app.hide()
        }

        if let finder = NSWorkspace.shared.runningApplications.first(where: \.isFinder) {
            finder.activate()
        }
    }

    func hideUnassignedApps() {
        guard let id = activeWorkspaceDetails?.id,
              let activeWorkspace = workspaceRepository.findWorkspace(with: id) else { return }

        let appsToHide = NSWorkspace.shared.runningApplications
            .regularVisibleApps(onDisplays: activeWorkspace.displays, excluding: activeWorkspace.apps)

        for app in appsToHide {
            Logger.log("CLEAN UP: \(app.localizedName ?? "")")

            if !pictureInPictureManager.hidePipAppIfNeeded(app: app) {
                app.hide()
            }
        }
    }

    func showUnassignedApps() {
        guard let display = DisplayName.currentOptional else { return }

        Logger.log("")
        Logger.log("")
        Logger.log("SHOW UNASSIGNED APPS")

        let allWorkspacesApps = workspaceRepository.workspaces.flatMap(\.apps)
        let unassignedApps = NSWorkspace.shared.runningApplications
            .regularApps(onDisplays: [display], excluding: allWorkspacesApps)
        let appsToHide = NSWorkspace.shared.runningApplications
            .regularVisibleApps(onDisplays: [display], excluding: unassignedApps.map(\.toMacApp))

        focusedWindowTracker.stopTracking()
        defer { focusedWindowTracker.startTracking() }

        deactivateActiveWorkspace(on: display)

        for app in unassignedApps {
            Logger.log("SHOW UNASSIGNED: \(app.localizedName ?? "")")
            app.raise()
        }

        for app in appsToHide {
            if unassignedApps.isNotEmpty || !app.isFinder {
                Logger.log("HIDE ASSIGNED: \(app.localizedName ?? "")")

                if !pictureInPictureManager.hidePipAppIfNeeded(app: app) {
                    app.hide()
                }
            }
        }

        (unassignedApps.first ?? NSWorkspace.shared.runningApplications.first(where: \.isFinder))?
            .activate()
    }

    func activateWorkspace(next: Bool, skipEmpty: Bool, loop: Bool) {
        let screen = workspaceSettings.switchWorkspaceOnCursorScreen
            ? displayManager.getCursorScreen()
            : DisplayName.currentOptional

        guard let screen else { return }

        var workspacesToLoop = workspaceRepository.workspaces

        if !workspaceSettings.loopWorkspacesOnAllDisplays {
            workspacesToLoop = workspacesToLoop
                .filter { $0.displays.contains(screen) }
        }

        if !next {
            workspacesToLoop = workspacesToLoop.reversed()
        }

        guard let activeWorkspace = activeWorkspace[screen] ?? workspacesToLoop.first else { return }

        let nextWorkspaces = workspacesToLoop
            .drop(while: { $0.id != activeWorkspace.id })
            .dropFirst()

        var selectedWorkspace = nextWorkspaces.first ?? (loop ? workspacesToLoop.first : nil)

        if skipEmpty {
            let runningApps = NSWorkspace.shared.runningRegularApps
                .compactMap(\.bundleIdentifier)
                .asSet

            selectedWorkspace = (nextWorkspaces + (loop ? workspacesToLoop : []))
                .drop(while: { $0.apps.allSatisfy { !runningApps.contains($0.bundleIdentifier) } })
                .first
        }

        guard let selectedWorkspace, selectedWorkspace.id != activeWorkspace.id else { return }

        activateWorkspace(selectedWorkspace, setFocus: true)
    }

    func activateRecentWorkspace() {
        guard let screen = displayManager.getCursorScreen(),
              let mostRecentWorkspace = mostRecentWorkspace[screen]
        else { return }

        activateWorkspace(mostRecentWorkspace, setFocus: true)
    }

    func activateWorkspaceIfActive(_ workspaceId: WorkspaceID) {
        guard activeWorkspace.values.contains(where: { $0.id == workspaceId }) else { return }
        guard let updatedWorkspace = workspaceRepository.findWorkspace(with: workspaceId) else { return }

        activateWorkspace(updatedWorkspace, setFocus: false)
    }

    func updateLastFocusedApp(_ app: MacApp, in workspace: Workspace) {
        lastFocusedApp[profilesRepository.selectedProfile.id, default: [:]][workspace.id] = app
    }

    func invalidateInactiveWorkspaces() {
        guard workspaceSettings.displayMode == .dynamic else { return }

        activeWorkspace = activeWorkspace.filter { display, workspace in
            let isValid = workspace.displays.contains(display)
            if !isValid {
                Logger.log("Invalidating workspace: \(workspace.name) on display: \(display)")
            }
            return isValid
        }
    }

    func pauseWorkspaceManagement() {
        guard !workspaceSettings.isPaused else { return }

        Logger.log("Pausing workspace management")
        workspaceSettings.isPaused = true
        focusedWindowTracker.stopTracking()
    }

    func resumeWorkspaceManagement() {
        guard workspaceSettings.isPaused else { return }

        Logger.log("Resuming workspace management")
        workspaceSettings.isPaused = false
        focusedWindowTracker.startTracking()
    }

    func togglePauseWorkspaceManagement() {
        if workspaceSettings.isPaused {
            resumeWorkspaceManagement()
        } else {
            pauseWorkspaceManagement()
        }
    }
}

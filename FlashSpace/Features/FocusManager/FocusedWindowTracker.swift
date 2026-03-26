//
//  FocusedWindowTracker.swift
//
//  Created by Wojciech Kulik on 20/01/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit
import Combine

final class FocusedWindowTracker {
    private var cancellables = Set<AnyCancellable>()
    private var profileAwareWindowObserver: AXObserver?
    private var observedProfileAwarePid: pid_t?

    private let workspaceRepository: WorkspaceRepository
    private let workspaceManager: WorkspaceManager
    private let settingsRepository: SettingsRepository
    private let pictureInPictureManager: PictureInPictureManager

    init(
        workspaceRepository: WorkspaceRepository,
        workspaceManager: WorkspaceManager,
        settingsRepository: SettingsRepository,
        pictureInPictureManager: PictureInPictureManager
    ) {
        self.workspaceRepository = workspaceRepository
        self.workspaceManager = workspaceManager
        self.settingsRepository = settingsRepository
        self.pictureInPictureManager = pictureInPictureManager

        activateWorkspaceForFocusedApp(force: true)
    }

    func startTracking() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.activationPolicy == .regular }
            .removeDuplicates()
            .sink { [weak self] app in
                self?.activeApplicationChanged(app, force: false)
                self?.autoAssignAppToWorkspaceIfNeeded(app)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .profileChanged)
            .sink { [weak self] _ in self?.activateWorkspaceForFocusedApp() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .delay(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.activateWorkspaceForFocusedApp(force: true) }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .profileAwareFocusedWindowChanged)
            .sink { [weak self] _ in self?.profileAwareFocusedWindowChanged() }
            .store(in: &cancellables)

        updateProfileAwareWindowObserver(for: NSWorkspace.shared.frontmostApplication)
    }

    func stopTracking() {
        cancellables.removeAll()
        removeProfileAwareWindowObserver()
    }

    private func activateWorkspaceForFocusedApp(force: Bool = false) {
        DispatchQueue.main.async {
            guard let activeApp = NSWorkspace.shared.frontmostApplication else { return }

            self.activeApplicationChanged(activeApp, force: force)
        }
    }

    private func activeApplicationChanged(_ app: NSRunningApplication, force: Bool) {
        updateProfileAwareWindowObserver(for: app)

        let workspaceSettings = settingsRepository.workspaceSettings
        let pipSettings = settingsRepository.pictureInPictureSettings
        let shouldActivate = workspaceSettings.activeWorkspaceOnFocusChange &&
            (!workspaceSettings.autoAssignAppsToWorkspaces || !workspaceSettings.autoAssignAlreadyAssignedApps)

        guard force || shouldActivate else { return }

        let activeWorkspaces = workspaceManager.activeWorkspace.values

        // Skip if the workspace was activated recently
        guard Date().timeIntervalSince(workspaceManager.lastWorkspaceActivation) > 0.2 else { return }

        // Skip if the app is floating
        guard !settingsRepository.floatingAppsSettings.floatingApps.containsApp(app) else { return }

        workspaceManager.invalidateInactiveWorkspaces()

        let prioritizedWorkspaces = Array(activeWorkspaces) + workspaceRepository.workspaces
        let workspace = workspaceManager.workspaceForProfileAwareWindow(
            app,
            prioritizedWorkspaces: prioritizedWorkspaces
        ) ?? prioritizedWorkspaces.first(where: { $0.apps.containsApp(app) })

        // Find the workspace that contains the app.
        // The same app can be in multiple workspaces, the highest priority has the one
        // from the active workspace.
        guard let workspace else { return }

        // Skip if the workspace is already active
        guard activeWorkspaces.count(where: { $0.id == workspace.id }) < workspace.displays.count else { return }

        // Skip if the focused window is in Picture in Picture mode
        guard !pipSettings.enablePictureInPictureSupport ||
            !app.supportsPictureInPicture ||
            app.focusedWindow?.isPictureInPicture(bundleId: app.bundleIdentifier) != true else { return }

        let activate = { [self] in
            Logger.log("")
            Logger.log("")
            Logger.log("Activating workspace for app: \(workspace.name)")
            if !workspaceManager.rememberFocusedProfileAwareWindow(app, in: workspace) {
                workspaceManager.updateLastFocusedApp(app.toMacApp, in: workspace)
            }
            workspaceManager.activateWorkspace(workspace, setFocus: false)
            app.activate()

            // Restore the app if it was hidden
            if pipSettings.enablePictureInPictureSupport, app.supportsPictureInPicture {
                pictureInPictureManager.restoreAppIfNeeded(app: app)
            }
        }

        if workspace.isDynamic, workspace.displays.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
                activate()
            }
        } else {
            activate()
        }
    }

    private func profileAwareFocusedWindowChanged() {
        DispatchQueue.main.async {
            guard let app = NSWorkspace.shared.frontmostApplication else { return }

            let prioritizedWorkspaces = Array(self.workspaceManager.activeWorkspace.values) +
                self.workspaceRepository.workspaces

            if let workspace = self.workspaceManager.workspaceForProfileAwareWindow(
                app,
                prioritizedWorkspaces: prioritizedWorkspaces
            ) {
                _ = self.workspaceManager.rememberFocusedProfileAwareWindow(app, in: workspace)

                let activeWorkspaces = self.workspaceManager.activeWorkspace.values
                let isWorkspaceActive = activeWorkspaces
                    .count(where: { $0.id == workspace.id }) >= workspace.displays.count

                guard !isWorkspaceActive else { return }

                self.workspaceManager.activateWorkspace(workspace, setFocus: false)
                app.activate()
                return
            }

            _ = self.workspaceManager.rememberFocusedProfileAwareWindow(app)
        }
    }

    private func updateProfileAwareWindowObserver(for app: NSRunningApplication?) {
        guard let app, shouldObserveProfileAwareWindowChanges(for: app) else {
            removeProfileAwareWindowObserver()
            return
        }

        guard observedProfileAwarePid != app.processIdentifier else { return }

        removeProfileAwareWindowObserver()

        let callback: AXObserverCallback = { _, _, _, _ in
            NotificationCenter.default.post(name: .profileAwareFocusedWindowChanged, object: nil)
        }
        var observer: AXObserver?
        let result = AXObserverCreate(app.processIdentifier, callback, &observer)

        guard result == .success, let observer else { return }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        AXObserverAddNotification(observer, appRef, kAXFocusedWindowChangedNotification as CFString, nil)
        AXObserverAddNotification(observer, appRef, kAXMainWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)

        profileAwareWindowObserver = observer
        observedProfileAwarePid = app.processIdentifier
    }

    private func removeProfileAwareWindowObserver() {
        guard let observer = profileAwareWindowObserver else {
            observedProfileAwarePid = nil
            return
        }

        if let observedProfileAwarePid {
            let appRef = AXUIElementCreateApplication(observedProfileAwarePid)
            AXObserverRemoveNotification(observer, appRef, kAXFocusedWindowChangedNotification as CFString)
            AXObserverRemoveNotification(observer, appRef, kAXMainWindowChangedNotification as CFString)
        }

        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        profileAwareWindowObserver = nil
        observedProfileAwarePid = nil
    }

    private func shouldObserveProfileAwareWindowChanges(for app: NSRunningApplication) -> Bool {
        workspaceRepository.workspaces
            .flatMap(\.profileAwareApps)
            .contains { $0.bundleIdentifier == app.bundleIdentifier }
    }

    private func autoAssignAppToWorkspaceIfNeeded(_ app: NSRunningApplication) {
        guard settingsRepository.workspaceSettings.autoAssignAppsToWorkspaces else { return }

        // Skip if the app is floating
        guard !settingsRepository.floatingAppsSettings.floatingApps.containsApp(app) else { return }

        let workspaceWithApp = workspaceRepository.workspaces.first { $0.apps.containsApp(app) }

        // Skip if the app is already assigned to a workspace
        guard settingsRepository.workspaceSettings.autoAssignAlreadyAssignedApps ||
            workspaceWithApp == nil else { return }

        // Assign the app to the active workspace on the same display, or to the first active workspace if there is no active
        // workspace on the same display
        let display = DisplayName.current
        let activeWorkspaces = workspaceManager.activeWorkspace.values
        var activeWorkspace = activeWorkspaces.first { $0.displays.contains(display) }
            ?? activeWorkspaces.first

        if settingsRepository.workspaceSettings.displayMode == .dynamic,
           workspaceManager.activeWorkspace.isEmpty,
           activeWorkspace == nil {
            activeWorkspace = workspaceRepository.workspaces.first
        }

        if let activeWorkspace, activeWorkspace.id != workspaceWithApp?.id {
            workspaceManager.assignApp(app.toMacApp, to: activeWorkspace)
        }
    }
}

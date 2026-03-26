//
//  ProfileAwareWindowAssignments.swift
//
//  Created by Codex on 26/03/2026.
//

import AppKit
import CoreGraphics

struct ProfileAwareWindowAssignments {
    struct Entry {
        let windowId: CGWindowID
        let window: AXUIElement
    }

    private var values: [WorkspaceID: [MacApp: Entry]] = [:]

    mutating func remember(windowId: CGWindowID, window: AXUIElement, for app: MacApp, in workspaceId: WorkspaceID) {
        values[workspaceId, default: [:]][app] = Entry(windowId: windowId, window: window)
    }

    func windowId(for app: MacApp, in workspaceId: WorkspaceID) -> CGWindowID? {
        values[workspaceId]?[app]?.windowId
    }

    func window(for app: MacApp, in workspaceId: WorkspaceID) -> AXUIElement? {
        values[workspaceId]?[app]?.window
    }

    func windowIds(in workspaceId: WorkspaceID) -> Set<CGWindowID> {
        Set(values[workspaceId]?.values.map(\.windowId) ?? [])
    }

    func workspaceId(for windowId: CGWindowID, prioritizedWorkspaces: [Workspace]) -> WorkspaceID? {
        prioritizedWorkspaces.first { windowIds(in: $0.id).contains(windowId) }?.id
    }
}

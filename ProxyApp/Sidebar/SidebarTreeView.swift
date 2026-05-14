//
//  SidebarTreeView.swift
//  ProxyApp
//
//  Three-level tree sidebar (Device → App → Domain) modelled on Proxyman.
//  Selection at any level filters the log table accordingly.
//

import SwiftUI

struct SidebarTreeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @Binding var searchText: String

    var body: some View {
        Group {
            if viewModel.sidebarTree.isEmpty {
                emptyState
            } else {
                tree
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Filter device, app, domain")
    }

    // MARK: - Tree

    private var tree: some View {
        List(selection: $viewModel.selectedSidebarItem) {
            ForEach(filteredTree, id: \.id) { device in
                DisclosureGroup {
                    ForEach(device.children ?? [], id: \.id) { app in
                        DisclosureGroup {
                            ForEach(app.children ?? [], id: \.id) { domain in
                                SidebarRow.domain(item: domain)
                                    .tag(domain)
                            }
                        } label: {
                            SidebarRow.app(
                                item: app,
                                isIntercepting: viewModel.interceptState(for: app.bundleID),
                                onToggleIntercept: { newValue in
                                    Task {
                                        guard let bid = app.bundleID else { return }
                                        await viewModel.setIntercept(
                                            bundleID: bid,
                                            name: app.title,
                                            on: newValue
                                        )
                                    }
                                }
                            )
                            .tag(app)
                            .contextMenu { appContextMenu(for: app) }
                        }
                    }
                } label: {
                    SidebarRow.device(item: device)
                        .tag(device)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 32))
                .foregroundStyle(Surface.secondaryText)
            Text("Waiting for traffic")
                .font(Typography.headline)
            Text("Start the proxy, install the CA on your simulator, then make a request from your app to see it appear here.")
                .font(Typography.caption)
                .foregroundStyle(Surface.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.lg)
    }

    // MARK: - Filtering

    /// Applies the search text to the tree. A device matches if any of its
    /// descendants (app name, bundle id, domain) match — that way the user
    /// always sees enough context to know "where" the match comes from.
    private var filteredTree: [SidebarItem] {
        guard !searchText.isEmpty else { return viewModel.sidebarTree }
        let needle = searchText.lowercased()
        return viewModel.sidebarTree.compactMap { device in
            let matchedApps: [SidebarItem] = (device.children ?? []).compactMap { app in
                let appHit = app.title.lowercased().contains(needle)
                    || (app.bundleID?.lowercased().contains(needle) ?? false)
                let matchedDomains = (app.children ?? []).filter { $0.title.lowercased().contains(needle) }
                if appHit && matchedDomains.isEmpty { return app }
                if appHit { return appWith(children: matchedDomains, base: app) }
                if !matchedDomains.isEmpty { return appWith(children: matchedDomains, base: app) }
                return nil
            }
            let deviceHit = device.title.lowercased().contains(needle)
            if deviceHit && matchedApps.isEmpty { return device }
            if !matchedApps.isEmpty {
                return deviceWith(children: matchedApps, base: device)
            }
            return nil
        }
    }

    private func appWith(children: [SidebarItem], base: SidebarItem) -> SidebarItem {
        SidebarItem(
            id: base.id, kind: base.kind, title: base.title, subtitle: base.subtitle,
            clientIPRoot: base.clientIPRoot, bundleID: base.bundleID, domain: base.domain,
            deviceKind: base.deviceKind, lastSeen: base.lastSeen, lastStatusCode: base.lastStatusCode,
            logCount: base.logCount, children: children
        )
    }

    private func deviceWith(children: [SidebarItem], base: SidebarItem) -> SidebarItem {
        SidebarItem(
            id: base.id, kind: base.kind, title: base.title, subtitle: base.subtitle,
            clientIPRoot: base.clientIPRoot, bundleID: base.bundleID, domain: base.domain,
            deviceKind: base.deviceKind, lastSeen: base.lastSeen, lastStatusCode: base.lastStatusCode,
            logCount: base.logCount, children: children
        )
    }

    // MARK: - Context menu

    @ViewBuilder
    private func appContextMenu(for item: SidebarItem) -> some View {
        if let bundleID = item.bundleID {
            Button("Copy Bundle ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bundleID, forType: .string)
            }
            let isOn = viewModel.interceptState(for: bundleID)
            Button(isOn ? "Disable HTTPS Interception" : "Enable HTTPS Interception") {
                Task {
                    await viewModel.setIntercept(bundleID: bundleID, name: item.title, on: !isOn)
                }
            }
        }
    }
}

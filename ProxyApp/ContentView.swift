//
//  ContentView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 27/03/25.
//

import SwiftUI

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var proxyCore: ProxyCore
    @EnvironmentObject private var authViewModel: AuthorizeAppViewModel
    @StateObject private var viewModel: HomeViewModel
    @State private var searchText: String = ""
    @State private var searchPath: String = ""
    @State private var showSimulatorSheet: Bool = false
    @State private var showProxyErrorAlert: Bool = false

    init(proxyCore: ProxyCore) {
        _viewModel = StateObject(wrappedValue: HomeViewModel(proxyCore: proxyCore))
    }
    
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    proxyCore.startDaemon()
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(proxyCore.isRunning)
                .help("Start proxy daemon")
                .accessibilityLabel("Start proxy")

                Button {
                    proxyCore.stopDaemon()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .disabled(!proxyCore.isRunning)
                .help("Stop proxy daemon")
                .accessibilityLabel("Stop proxy")

                Menu {
                    Button("Install on iOS Simulator…") {
                        showSimulatorSheet = true
                    }
                } label: {
                    Image(systemName: "lock.shield")
                }
                .help("Certificate")
                .accessibilityLabel("Certificate menu")

                ProxyStatusPill(
                    isRunning: proxyCore.isRunning,
                    localIP: viewModel.ipOnEthernet()
                )
            }
        }

        
        .sheet(isPresented: $authViewModel.showAuthorizationSheet) {
            AuthAppView()
        }
        .sheet(isPresented: $showSimulatorSheet) {
            SimulatorCertificateView()
        }
        .onChange(of: proxyCore.lastError) { _, newValue in
            showProxyErrorAlert = (newValue?.isEmpty == false)
        }
        .alert("Proxy", isPresented: $showProxyErrorAlert, presenting: proxyCore.lastError) { _ in
            Button("OK") { showProxyErrorAlert = false }
        } message: { msg in
            Text(msg)
        }
        .navigationTitle("")
    }
    
    // MARK: - Sidebar (Left)
    private var sidebar: some View {
        SidebarTreeView(viewModel: viewModel, searchText: $searchPath)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
    }
    
    
    private var detailView: some View {
        VSplitView {
            VStack(spacing: 0) {
                connectionBanner
                if viewModel.selectedSidebarItem == nil {
                    welcomeView
                } else {
                    LogTableView(
                        viewModel: viewModel,
                        logs: viewModel.filteredLogs,
                        filter: $searchText
                    )
                    .searchable(text: $searchText, placement: .toolbar, prompt: "Filter requests")
                }
            }

            if let selected = viewModel.selectedLog {
                LogDetailView(log: selected)
                    .frame(minHeight: 200, maxHeight: .infinity)
            } else {
                detailPlaceholder
            }
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        switch proxyCore.connectionState {
        case .connecting:
            BannerView(
                icon: "antenna.radiowaves.left.and.right",
                tint: .blue,
                title: "Connecting to daemon",
                message: "Waiting for proxycore to respond on 127.0.0.1:8081…"
            )
        case .retrying(let attempt):
            BannerView(
                icon: "arrow.triangle.2.circlepath",
                tint: .orange,
                title: "Reconnecting (attempt \(attempt))",
                message: "Lost connection to the daemon. Retrying with backoff."
            )
        case .failed(let reason):
            BannerView(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: "Daemon unavailable",
                message: reason
            )
        case .connected, .idle:
            EmptyView()
        }
    }

    private var welcomeView: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: proxyCore.isRunning ? "wave.3.right" : "play.rectangle")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Surface.secondaryText)

            Text(proxyCore.isRunning ? "Listening for requests" : "PacketPeek is idle")
                .font(Typography.title)

            VStack(alignment: .leading, spacing: Spacing.md) {
                welcomeStep(
                    n: 1,
                    text: proxyCore.isRunning ? "Proxy is running" : "Start the proxy from the toolbar",
                    done: proxyCore.isRunning
                )
                welcomeStep(
                    n: 2,
                    text: "Install the CA on your iOS Simulator (Certificate menu)",
                    done: false
                )
                welcomeStep(
                    n: 3,
                    text: "Make a request from the simulator — it will appear in the sidebar",
                    done: false
                )
            }
            .padding(Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(Surface.elevated)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }

    private func welcomeStep(n: Int, text: String, done: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Surface.separator)
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(n)")
                        .font(Typography.badge)
                        .foregroundStyle(Surface.secondaryText)
                }
            }
            Text(text)
                .font(Typography.body)
                .foregroundStyle(done ? Surface.secondaryText : .primary)
                .strikethrough(done, color: Surface.secondaryText)
        }
    }

    private var detailPlaceholder: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(Surface.secondaryText)
            Text("Select a request to inspect")
                .font(Typography.caption)
                .foregroundStyle(Surface.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BannerView: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.badge).foregroundStyle(.primary)
                Text(message).font(Typography.caption).foregroundStyle(Surface.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(tint.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(tint.opacity(0.3)).frame(height: 0.5)
        }
    }
}

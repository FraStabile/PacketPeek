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
    @State private var searchIsActive: Bool = false
    @State private var searchText: String = ""
    @State private var searchPath: String = ""
    @State private var selectedBasePath: BasePathModel?
    
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
                .padding(.trailing, 8)

                Button {
                    proxyCore.stopDaemon()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .disabled(!proxyCore.isRunning)

                HStack(spacing: 10) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)

                    if proxyCore.isRunning {
                        HStack(spacing: 12) {
                            Text("127.0.0.1:8080")
                                .font(.caption)

                            if let localIP = viewModel.ipOnEthernet() {
                                Text("\(localIP):8080")
                                    .font(.caption)
                            } else {
                                Text("LAN IP: N/A")
                                    .font(.caption2)
                            }

                            Text("Running")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    } else {
                        HStack(spacing: 12) {
                            Text("Proxy Offline")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text("Click ▶ to start")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }

                    Circle()
                        .fill(proxyCore.isRunning ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.windowBackgroundColor).opacity(0.6))
                )
            }
        }

        
        .sheet(isPresented: $authViewModel.showAuthorizationSheet) {
            AuthAppView()
        }
        .navigationTitle("")
    }
    
    // MARK: - Sidebar (Left)
    private var sidebar: some View {
        
        var filterPath: [AgentModel] {
            if searchPath.isEmpty {
                return viewModel.agents
            }
            return viewModel.agents.filter({$0.basePaths.contains(where: {$0.basePath.lowercased().contains(searchPath.lowercased())})})
        }
        
        return List(selection: $selectedBasePath) {
            TextField("Cerca...", text: $searchPath)
                .padding(.vertical)
            ForEach(filterPath) { agent in
                Section(header: Text(agent.ip).bold()) {
                    ForEach(agent.basePaths) { basePath in
                        let isSelected = viewModel.filterIP == agent.ip && viewModel.filterPath == basePath.basePath
                        HStack {
                            Text(basePath.basePath)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    isSelected ? Color.accentColor.opacity(0.2) : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .contentShape(Rectangle()) // makes entire row tappable
                        .onTapGesture {
                            viewModel.filterIP = agent.ip
                            viewModel.filterPath = basePath.basePath
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
    }
    
    
    private var detailView: some View {
        VSplitView {
            VStack(spacing: 0) {
                KeyCaptureView { event in
                    if event.modifierFlags.contains(.command) && event.characters == "f" {
                        searchIsActive.toggle()
                    }
                }
                .frame(width: 0, height: 0)
                
                if searchIsActive {
                    HStack {
                        TextField("Cerca...", text: $searchText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding(8)
                        Button("Cancel") {
                            searchIsActive = false
                            searchText = ""
                        }
                        .padding(.trailing, 8)
                    }
                }
                
                // PRIMO PANNELLO: tabella con i risultati filtrati
                LogTableView(viewModel: viewModel, logs: viewModel.listBasePathRequest(), filter: $searchText)
            }
            
            // SECONDO PANNELLO: Dettaglio
            if let selected = viewModel.selectedLog {
                LogDetailView(log: selected)
                    .frame(minHeight: 200, maxHeight: .infinity)
            } else {
                Text("Nessun log selezionato")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
            }
        }
        
    }
}

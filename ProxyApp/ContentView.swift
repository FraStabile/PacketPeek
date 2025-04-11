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
    @StateObject private var viewModel: HomeViewModel
    
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
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                Button {
                    proxyCore.stopDaemon()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .disabled(!proxyCore.isRunning)
                HStack {
                    Circle()
                        .fill(proxyCore.isRunning ? Color.green : Color.red)
                        .frame(width: 20, height: 20)
                        .scaleEffect(proxyCore.isRunning ? 1 : 0.2)
                    Text(proxyCore.isRunning ? "Running" : "Not Running")
                }
                .padding(8)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(10)
                
            }
        }
    }
    
    // MARK: - Sidebar (Left)
    private var sidebar: some View {
        List(selection: $selectedBasePath) {
            ForEach(viewModel.agents) { agent in
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
            LogTableView(viewModel: viewModel, logs: viewModel.listBasePathRequest())
            
            if let selected = viewModel.selectedLog {
                Divider()
                LogDetailView(log: selected)
                    .frame(height: 300) // altezza del pannello in basso
                    .transition(.move(edge: .bottom))
            }
        }
    }
}

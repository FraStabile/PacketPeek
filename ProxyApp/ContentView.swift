//
//  ContentView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 27/03/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var proxyCore: ProxyCore
    @StateObject var viewModel: HomeViewModel
    
    init(proxyCore: ProxyCore) {
        _viewModel = StateObject(wrappedValue: HomeViewModel(proxyCore: proxyCore))
    }
    
    var body: some View {
        NavigationSplitView {
            // Colonna di sinistra con la lista degli IP unici
            List(viewModel.proxyUIModel, id: \.id) { ipModel in
                DisclosureGroup(ipModel.ip) {
                    List(ipModel.logs, id: \.id) { request in
                        Text("\(request.methodLabel) \(request.url)")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ProxyToolbarView()
                }
            }
        } detail: {
            // Dettaglio che mostra il testo se non è selezionato nulla
            Text("Select an item")
        }
    }
}


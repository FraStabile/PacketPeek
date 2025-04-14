//
//  ProxyAppApp.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 27/03/25.
//

import SwiftUI
import SwiftData

@main
struct ProxyAppApp: App {
    @StateObject var proxyCore: ProxyCore = ProxyCore()
    @StateObject var authViewModel: AuthorizeAppViewModel = AuthorizeAppViewModel()
    @State private var showTutorialModal = false
    
    var body: some Scene {
        WindowGroup {
            ContentView(proxyCore: proxyCore)
                .environmentObject(proxyCore)
                .environmentObject(authViewModel)
                .sheet(isPresented: $showTutorialModal) {
                    TutorialModalView()
                }
        }
        .commands {
            CommandMenu("Development") {
                Button("Authorize Apps") {
                    authViewModel.fetchAuthorizedApps()
                    authViewModel.showAuthorizationSheet.toggle()
                }
                .keyboardShortcut("A", modifiers: [.command, .shift])
            }
            
            CommandGroup(after: CommandGroupPlacement.help) {
                Button("Tutorial") {
                    showTutorialModal = true
                }
            }
        }
        
    }
}

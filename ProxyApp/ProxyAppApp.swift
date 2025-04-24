//
//  ProxyAppApp.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 27/03/25.
//

import SwiftUI
import SwiftData
import Papyrus
@main
struct ProxyAppApp: App {
    @StateObject var proxyCore: ProxyCore = ProxyCore()
    @StateObject var authViewModel: AuthorizeAppViewModel = AuthorizeAppViewModel()
    @StateObject var mockEditorViewModel: MockModalEditViewModel = MockModalEditViewModel()
    @StateObject var modalRouter = ModalRouter()
    var mainProvider: MainProvider = MainProvider()
    @Environment(\.openWindow) private var openWindow

    private let diManager = DependecyManager()
    var body: some Scene {
        WindowGroup("Settings", id: "settingsWindow") {
            MainSettingView()
        }
        WindowGroup {
            ContentView(proxyCore: proxyCore)
                .sheet(item: $modalRouter.activeModal) { modal in
                    switch modal {
                    case .tutorial:
                        TutorialModalView()
                    case .mockManager:
                        MockManagerView(viewModel: MockManagerViewModel())
                    case .editMock:
                        MockModalEditView(viewModel: mockEditorViewModel)
                    case .authorizeApps:
                        AuthAppView()
                    case AppModal.settings:
                        MainSettingView()
                    }
                }
                .environmentObject(proxyCore)
                .environmentObject(authViewModel)
                .environmentObject(mockEditorViewModel)
                .environmentObject(modalRouter)
                .environmentObject(MainProvider())
                
        }
        .commands {
            CommandMenu("Development") {
                Button("Authorize Apps") {
                    Task {
                        modalRouter.activeModal = .authorizeApps
                    }
                }
                .keyboardShortcut("A", modifiers: [.command, .shift])
                Button("Mock Manager") {
                    modalRouter.activeModal = .mockManager
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Impostazioni") {
                    openWindow(id: "settingsWindow")
                }
            }
            CommandGroup(after: CommandGroupPlacement.help) {
                Button("Tutorial") {
                    modalRouter.activeModal = .tutorial
                }
            }
        }
        
    }
}

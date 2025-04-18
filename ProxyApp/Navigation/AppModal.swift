//
//  AppModal.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 17/04/25.
//


import SwiftUI

enum AppModal: Identifiable {
    case tutorial
    case mockManager
    case editMock
    case authorizeApps
    var id: String {
        switch self {
        case .tutorial: return "tutorial"
        case .mockManager: return "mockManager"
        case .editMock: return "editMock"
        case .authorizeApps: return "authorizeApps"
        }
    }
}

final class ModalRouter: ObservableObject {
    @Published var activeModal: AppModal?
}

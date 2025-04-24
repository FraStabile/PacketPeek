//
//  DependecyManager.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 22/04/25.
//
import SwiftDependency

@MainActor
class DependecyManager {
    
    init() {
        Container.shared.register(MocksAPI.self, component: MainProvider().mocksService(), lifeCycle: .singleton)
        Container.shared.register(SettingsManagerProtocol.self, component: SettingsManager(), lifeCycle: .singleton)
    }
}

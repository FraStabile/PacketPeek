//
//  SettingsManagerProtocol.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 24/04/25.
//


protocol SettingsManagerProtocol {
    func saveSettings(_ settings: SettingsModel)
    func loadSettings() -> SettingsModel?
    func getDefaultSettings() -> SettingsModel
    func getCurrentSettings() -> SettingsModel
}

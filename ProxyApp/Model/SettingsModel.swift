//
//  SettingsModel.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 24/04/25.
//

import Foundation



class SettingsModel: Codable, ObservableObject {
    var general: GeneralSettingsModel
    
    init(general: GeneralSettingsModel) {
        self.general = general
    }
}

class GeneralSettingsModel: Codable {
    var theme: String
    var language: String
    init(theme: String, language: String) {
        self.theme = theme
        self.language = language
    }
}

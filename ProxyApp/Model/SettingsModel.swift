//
//  SettingsModel.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 24/04/25.
//

import Foundation
import SwiftUI

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

class SettingsModel: Codable, ObservableObject {
    var general: GeneralSettingsModel

    init(general: GeneralSettingsModel) {
        self.general = general
    }
}

class GeneralSettingsModel: Codable {
    var theme: Appearance
    var language: String

    init(theme: Appearance = .system, language: String = "it") {
        self.theme = theme
        self.language = language
    }

    enum CodingKeys: String, CodingKey {
        case theme, language
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.theme    = (try? c.decodeIfPresent(Appearance.self, forKey: .theme))    ?? .system
        self.language = (try? c.decodeIfPresent(String.self, forKey: .language))     ?? "it"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(theme, forKey: .theme)
        try c.encode(language, forKey: .language)
    }
}

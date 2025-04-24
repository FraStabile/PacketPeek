//
//  GeneralSettings.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 24/04/25.
//

import SwiftUI
class GeneralSettings: SettingsItemProtocol {
    var id: UUID = UUID()
    var name: String = "General"
    var icon: String? = "gear"
    func content() -> some View {
            GeneralSettingView()
        }
}

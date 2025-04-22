//
//  AuthorizeAppViewModel.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 14/04/25.
//

import Combine
import Foundation
import SwiftDependency
struct AuthorizedApp: Identifiable, Codable {
    var id: String { bundle_id }
    let bundle_id: String
    let name: String
    let decrypt_traffic: Bool
}

class AuthorizeAppViewModel: ObservableObject {
    @Published var showAuthorizationSheet = false
    @Published var showAddSheet = false

    @Published var bundleID: String = ""
    @Published var appName: String = ""
    @Published var isSubmitting = false
    @Published var errorMessage: String?

    @Published var authorizedApps: [AuthorizedApp] = []

    @InjectProps private var repo: MocksAPI
    
    func fetchAuthorizedApps() async {
        do {
            let response = try await repo.getApps()
            self.authorizedApps = response
        }
        catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func authorizeApp() async {
        guard !bundleID.isEmpty, !appName.isEmpty else {
            errorMessage = "Both fields are required."
            return
        }

        isSubmitting = true
        errorMessage = nil

        let request = AuthorizedApp(bundle_id: bundleID, name: appName, decrypt_traffic: true)
        
        do {
            try await repo.setApps(request)
            self.showAddSheet = false
            self.bundleID = ""
            self.appName = ""
            await self.fetchAuthorizedApps()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
    
    func disableDecryption(for app: AuthorizedApp) async {
        
        
        let request = AuthorizedApp(bundle_id: app.bundle_id, name: app.name, decrypt_traffic: false)
        
        do {
            try await repo.setApps(request)
            self.showAddSheet = false
            self.bundleID = ""
            self.appName = ""
            await self.fetchAuthorizedApps()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

}


//
//  AuthorizeAppViewModel.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 14/04/25.
//

import Combine
import Foundation
struct AuthorizedApp: Identifiable, Decodable {
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

    func fetchAuthorizedApps() {
        guard let url = URL(string: "http://localhost:8081/api/apps") else { return }

        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let data = data {
                    do {
                        let apps = try JSONDecoder().decode([AuthorizedApp].self, from: data)
                        self.authorizedApps = apps
                    } catch {
                        self.errorMessage = "Invalid response format"
                    }
                } else if let error = error {
                    self.errorMessage = error.localizedDescription
                }
            }
        }.resume()
    }

    func authorizeApp() {
        guard !bundleID.isEmpty, !appName.isEmpty else {
            errorMessage = "Both fields are required."
            return
        }

        isSubmitting = true
        errorMessage = nil

        let url = URL(string: "http://localhost:8081/api/apps")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "bundle_id": bundleID,
            "name": appName,
            "decrypt_traffic": true
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            errorMessage = "Failed to encode payload."
            isSubmitting = false
            return
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                self.isSubmitting = false
                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                    self.errorMessage = "Authorization failed."
                    return
                }

                self.showAddSheet = false
                self.bundleID = ""
                self.appName = ""
                self.fetchAuthorizedApps()
            }
        }.resume()
    }
    
    func disableDecryption(for app: AuthorizedApp) {
        guard let url = URL(string: "http://localhost:8081/api/apps") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "bundle_id": app.bundle_id,
            "name": app.name,
            "decrypt_traffic": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            self.errorMessage = "Failed to encode disable request."
            return
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }

                self.fetchAuthorizedApps()
            }
        }.resume()
    }

}


//
//  AuthAppView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 14/04/25.
//

import SwiftUI

struct AuthAppView: View {
    @EnvironmentObject var viewModel: AuthorizeAppViewModel
    private var filterApp: [AuthorizedApp] {
        viewModel.authorizedApps.filter({$0.decrypt_traffic})
    }
    var body: some View {
        VStack(spacing: 16) {
            Text("Authorized Apps")
                .font(.title2)
                .padding(.top)
            
            Table(filterApp) {
                TableColumn("Bundle ID") { app in
                    Text(app.bundle_id)
                }
                TableColumn("Name") { app in
                    Text(app.name)
                }
                TableColumn("Decrypt Traffic") { app in
                    Image(systemName: app.decrypt_traffic ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(app.decrypt_traffic ? .green : .red)
                }
                TableColumn("Actions") { app in
                    Button(role: .destructive) {
                        viewModel.disableDecryption(for: app)
                    } label: {
                        Label("Disable", systemImage: "trash")
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            }
            .frame(minHeight: 200)
            
            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundColor(.red)
            }
            
            HStack {
                Button("Close") {
                    viewModel.showAuthorizationSheet = false
                }
                
                Spacer()
                
                Button("Add New App") {
                    viewModel.showAddSheet = true
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .padding()
        .frame(width: 600)
        .sheet(isPresented: $viewModel.showAddSheet) {
            AddAppSheet()
        }
    }
}

#Preview {
    AuthAppView()
}

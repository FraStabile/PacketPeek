//
//  AddAppSheet.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 14/04/25.
//

import SwiftUI

struct AddAppSheet: View {
    @EnvironmentObject var viewModel: AuthorizeAppViewModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Add New App")
                .font(.headline)

            TextField("Bundle ID (e.g. app.exaple.ios)", text: $viewModel.bundleID)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()

            TextField("App Name", text: $viewModel.appName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundColor(.red)
            }

            HStack {
                Button("Cancel") {
                    viewModel.showAddSheet = false
                }

                Button("Authorize") {
                    viewModel.authorizeApp()
                }
                .disabled(viewModel.isSubmitting)
            }
            .padding(.bottom)
        }
        .frame(width: 400)
        .padding()
    }
}


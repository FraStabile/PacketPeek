//
//  MockManagerView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 17/04/25.
//


import SwiftUI
import Combine
struct MockManagerView: View {
    @StateObject var viewModel: MockManagerViewModel
    @State private var selectedMock: MockItemRequest?
    @State private var showEditSheet = false
    @State private var showDeleteAlert: MockItemRequest?
    
    @EnvironmentObject var modalRouter: ModalRouter
    @EnvironmentObject var provider: MainProvider
    @EnvironmentObject var editMock: MockModalEditViewModel
    init(viewModel: MockManagerViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Registered Mocks")
                .font(.title2)
                .padding(.top)
            
            Table(viewModel.mocks) {
                TableColumn("Method") { mock in
                    Text(mock.method)
                }
                TableColumn("Host") { mock in
                    Text(mock.host)
                }
                TableColumn("Path") { mock in
                    Text(mock.path)
                }
                TableColumn("Status") { mock in
                    Text("\(mock.statusCode)")
                }
                TableColumn("Latency") { mock in
                    Text("\(mock.latencyMS) ms")
                }
                TableColumn("Enabled") { mock in
                    ToggleMockView(mock: mock, viewModel: viewModel)
                }
                TableColumn("Actions") { (mock: MockItemRequest) in
                    MockActionsView(
                        mock: mock,
                        onEdit: {
                            selectedMock = mock
                            modalRouter.activeModal = .editMock
                            editMock.setupProxyLog(proxyLog: ProxyLog(
                                method: mock.method,
                                url: "https://" + mock.host + mock.path,
                                protocol: mock.method,
                                clientIP: "",
                                requestHeaders: [:],
                                requestBody: "",
                                statusCode: mock.statusCode,
                                responseHeaders: [:],
                                responseBody: mock.response,
                                responseTime: Double(mock.latencyMS),
                                timestamp: Date(),
                                completed: Date(),
                                userAgent: "",
                                deviceInfo: "",
                                isSimulator: true,
                                appIdentifier: ""
                            ))
                        },
                        onDelete: {
                            showDeleteAlert = mock
                        }
                    )
                }
            }
            .frame(minHeight: 200)
            
            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundColor(.red)
            }
            
            HStack {
                Button("Close") {
                    modalRouter.activeModal = nil
                }
                
                Spacer()
            }
            .padding()
        }
        .padding()
        .frame(minWidth: 800)
        .onAppear {
            Task {
                await viewModel.fetchMocks()
            }
        }
        .alert("Delete Mock", isPresented: Binding(get: {
            showDeleteAlert != nil
        }, set: { if !$0 { showDeleteAlert = nil } }), presenting: showDeleteAlert) { mock in
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteMock(mock: mock)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { mock in
            Text("Are you sure you want to delete the mock for \(mock.method) \(mock.path)?")
        }
    }
}


struct MockActionsView: View {
    var mock: MockItemRequest
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack {
            Button("Edit", action: onEdit)
                .buttonStyle(BorderlessButtonStyle())

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(BorderlessButtonStyle())
        }
    }
}


struct ToggleMockView: View {
    var mock: MockItemRequest
    var viewModel: MockManagerViewModel

    var body: some View {
        Toggle("", isOn: Binding<Bool>(
            get: { mock.isActive },
            set: { newValue in
                Task {
                    await viewModel.toggleMock(mock: mock, isActive: newValue)
                }
            }
        ))
        .labelsHidden()
    }
}


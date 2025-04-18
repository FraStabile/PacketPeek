//
//  MockManagerViewModel.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 17/04/25.
//

import Combine
import Foundation
import SwiftUI

@MainActor
class MockManagerViewModel: ObservableObject {
    @Published var mocks: [MockItemRequest] = []
    @Published var showAddSheet: Bool = false
    @Published var showEditSheet: Bool = false
    @Published var errorMessage: String?
    private var mockRepo: MocksAPI?
    
    func setupRepo(repo: MocksAPI) {
        self.mockRepo = repo
    }
    func fetchMocks() async {
        do {
            let response = try await mockRepo?.getMocks()
            mocks = response ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    func deleteMock(mock: MockItemRequest) async {
        do {
            let _ = try await mockRepo?.deleteMock(id: mock.id)
            let response = try await mockRepo?.getMocks()
            mocks = response ?? []
        } catch {
            errorMessage = error.localizedDescription
        }

    }
    
    func toggleMock(mock: MockItemRequest, isActive: Bool) async {
        var updateMock = mock
        updateMock.isActive = isActive
        var urlRequest = URLRequest(url: URL(string: "http://localhost:8081/api/mocks")!)
        do {
            urlRequest.httpBody = try JSONEncoder().encode(updateMock)
            urlRequest.httpMethod = "POST"
            _ = try await URLSession.shared.data(for: urlRequest)
            if let index = mocks.firstIndex(where: { $0.id == mock.id }) {
                mocks[index] = updateMock
            }
        } catch {
            
        }
    }

}

//
//  MockManagerViewModel.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 17/04/25.
//

import Combine
import Foundation
import SwiftUI
import SwiftDependency

class MockManagerViewModel: BaseViewModel {
    @Published var mocks: [MockItemRequest] = []
    @Published var showAddSheet: Bool = false
    @Published var showEditSheet: Bool = false
    @Published var errorMessage: String?
    @InjectProps private var repo: MocksAPI
    
    func fetchMocks() async {
        do {
            let response = try await repo.getMocks()
            mocks = response
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    func deleteMock(mock: MockItemRequest) async {
        do {
            let _ = try await repo.deleteMock(id: mock.id)
            let response = try await repo.getMocks()
            mocks = response
        } catch {
            errorMessage = error.localizedDescription
        }

    }
    
    func toggleMock(mock: MockItemRequest, isActive: Bool) async {
        var updateMock = mock
        updateMock.isActive = isActive
        do {
            try await repo.updateMock(updateMock)
            if let index = mocks.firstIndex(where: { $0.id == mock.id }) {
                mocks[index] = updateMock
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

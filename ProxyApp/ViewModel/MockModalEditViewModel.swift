//
//  MockModalEdit.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 15/04/25.
//

import Combine
import Foundation
import SwiftDependency
class MockModalEditViewModel: BaseViewModel {
    @Published var isPresented: Bool = false
    @Published var log: ProxyLog = ProxyLog()
    @Published var latency: String = "0"
    @Published var response: String = """
    {
        "glossary": {
            "title": "example glossary",
            "GlossDiv": {
                "title": "S",
                "GlossList": {
                    "GlossEntry": {
                        "ID": "SGML",
                        "SortAs": "SGML",
                        "GlossTerm": "Standard Generalized Markup Language",
                        "Acronym": "SGML",
                        "Abbrev": "ISO 8879:1986",
                        "GlossDef": {
                            "para": "A meta-markup language, used to create markup languages such as DocBook.",
                            "GlossSeeAlso": ["GML", "XML"]
                        },
                        "GlossSee": "markup"
                    }
                }
            }
        }
    }
    """

    @InjectProps private var repo: MocksAPI
    @Published var statusCode: String = ""
    @Published var errorMessage: String?
    @Published private(set) var isSaving = false

    /// The mock being edited, when opened from the mock manager. Its identity
    /// and flags (id, isActive, isRegex, contentType, host, path) are preserved
    /// on save; nil when creating a new mock from a captured request.
    private var existingMock: MockItemRequest?

    func dismiss() {
        isPresented = false
    }

    /// Prepare the sheet to create a new mock from a captured request.
    func setupProxyLog(proxyLog: ProxyLog) {
        existingMock = nil
        log = proxyLog
        response = proxyLog.responseBody ?? ""
        statusCode = String(proxyLog.statusCode)
        latency = "0"
        errorMessage = nil
    }

    /// Prepare the sheet to edit an existing mock.
    func setupMock(_ mock: MockItemRequest) {
        existingMock = mock
        log = ProxyLog(
            method: mock.method,
            url: "https://" + mock.host + mock.path,
            statusCode: mock.statusCode,
            responseBody: mock.response,
            responseTime: Double(mock.latencyMS)
        )
        response = mock.response
        statusCode = String(mock.statusCode)
        latency = String(mock.latencyMS)
        errorMessage = nil
    }

    /// Validates the form and returns the field values, or sets errorMessage.
    private func validatedInput() -> (status: Int, latency: Int)? {
        guard let status = Int(statusCode.trim()), (100...599).contains(status) else {
            errorMessage = "Status code non valido: inserisci un numero tra 100 e 599."
            return nil
        }
        let latencyText = latency.trim()
        guard let latencyMS = latencyText.isEmpty ? 0 : Int(latencyText), latencyMS >= 0 else {
            errorMessage = "Latenza non valida: inserisci un numero di millisecondi ≥ 0."
            return nil
        }
        return (status, latencyMS)
    }

    private var contentTypeForNewMock: String {
        let header = log.responseHeaders.first { $0.key.lowercased() == "content-type" }?.value
        return header?.isEmpty == false ? header! : "application/json"
    }

    /// Saves the mock. Returns true on success; on failure errorMessage is set
    /// and the sheet should stay open.
    @MainActor
    func save() async -> Bool {
        errorMessage = nil
        guard let input = validatedInput() else { return false }

        let requestData: MockItemRequest
        if let existing = existingMock {
            requestData = MockItemRequest(
                method: existing.method,
                host: existing.host,
                path: existing.path,
                isRegex: existing.isRegex,
                statusCode: input.status,
                latencyMS: input.latency,
                response: response.trim(),
                contentType: existing.contentType,
                isActive: existing.isActive,
                id: existing.id
            )
        } else {
            requestData = MockItemRequest(
                method: log.method,
                // Hostname only: the daemon matches mocks by hostname, ignoring the port.
                host: log.url.host,
                path: log.url.path,
                isRegex: false,
                statusCode: input.status,
                latencyMS: input.latency,
                response: response.trim(),
                contentType: contentTypeForNewMock,
                isActive: true
            )
        }

        isSaving = true
        defer { isSaving = false }
        do {
            try await repo.updateMock(requestData)
            return true
        } catch {
            errorMessage = "Salvataggio non riuscito: \(error.localizedDescription)"
            return false
        }
    }
}

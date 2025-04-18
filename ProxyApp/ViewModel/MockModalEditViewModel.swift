//
//  MockModalEdit.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 15/04/25.
//

import Combine
import Foundation
class MockModalEditViewModel: ObservableObject {
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

    @Published var statusCode: String = ""
    
    func dismiss() {
        isPresented = false
    }
    
    func setupProxyLog(proxyLog: ProxyLog) {
        self.log = proxyLog
        self.response = log.responseBody ?? ""
        self.statusCode = String(proxyLog.statusCode)
    }
    
    
    func setupMocks() async {
        var host = log.url.host
        if let port = log.url.port {
            host += ":\(port)"
        }
        let requestData = MockItemRequest(method: log.method, host: host, path: log.url.path, isRegex: false, statusCode: Int(statusCode) ?? 0, latencyMS: Int(statusCode) ?? 0, response: response.trim(), contentType: "application/json", isActive: true)
        do {
            var urlRequest = URLRequest(url: URL(string: "http://localhost:8081/api/mocks")!)
            urlRequest.httpBody = try JSONEncoder().encode(requestData)
            urlRequest.httpMethod = "POST"
            _ = try await URLSession.shared.data(for: urlRequest)
            print("Successo")
        } catch {
            print("Error")
        }
    }
}

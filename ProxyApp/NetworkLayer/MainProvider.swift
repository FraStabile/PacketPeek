//
//  MainProvider.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 17/04/25.
//

import Papyrus
import Foundation

/// Central place to construct Papyrus providers. The base URL is loopback by
/// design — the daemon's control plane binds to 127.0.0.1:8081. If we later
/// enable the Go-side `PACKETPEEK_AUTH=required` mode, this is also where the
/// bearer token interceptor should be wired in (Papyrus `modifyRequests`).
class MainProvider: ObservableObject {
    static let defaultBaseURL = "http://127.0.0.1:8081"

    let provider: Provider

    init(baseURL: String = MainProvider.defaultBaseURL) {
        self.provider = Provider(baseURL: baseURL)
    }

    func mocksService() -> MocksAPI {
        return MocksAPIAPI(provider: provider)
    }
}

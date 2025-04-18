//
//  MainProvider.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 17/04/25.
//

import Papyrus
class MainProvider: ObservableObject {
    let provider = Provider(baseURL: "http://localhost:8081")
    
    func mocksService() -> MocksAPI {
        return MocksAPIAPI(provider: provider)
    }
}

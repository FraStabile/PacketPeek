//
//  LogTableView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 11/04/25.
//
import SwiftUI
struct EmptySelectionView: View {
    var body: some View {
        VStack {
            Text("Select a base path to view logs.")
                .foregroundStyle(.secondary)
        }
    }
}

struct LogTableView: View {
    @ObservedObject var viewModel: HomeViewModel
    @EnvironmentObject var modalRouter: ModalRouter
    @EnvironmentObject var editViewModel: MockModalEditViewModel
    let logs: [ProxyLog] // Replace with your actual log type
    @Binding var filter: String
    init(viewModel: HomeViewModel, logs: [ProxyLog], filter: Binding<String>) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.logs = logs
        self._filter = filter
    }
    
    
    private var filteredLogs: [ProxyLog] {
        print("filter: \(filter)")
        if filter.isEmpty {
            return logs
        }
        return logs.filter {
            $0.clientIP.lowercased().contains(filter.lowercased()) || $0.method.lowercased().contains(filter.lowercased()) || $0.url.lowercased().contains(filter.lowercased())
        }
    }
    
    var body: some View {
        Table(filteredLogs, selection: $viewModel.selectedLogID) {
            TableColumn("Client") { log in
                Text(log.clientIP)
            }
            TableColumn("Method") { log in
                Text(log.method)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.blue)
            }
            
            TableColumn("Code") { (log: ProxyLog) in
                Text("\(log.statusCode)")
                    .foregroundStyle(log.statusCode == 200 ? .green : .orange)
            }
            TableColumn("Time") { (log: ProxyLog) in
                Text(log.timestamp.formatted(date: .omitted, time: .standard))
            }
            TableColumn("Duration") { (log: ProxyLog) in
                Text("\(log.responseTime) ms")
            }
            TableColumn("URL") { log in
                Text(log.url)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
        }
        .contextMenu(forSelectionType: ProxyLog.ID.self) { proxyLogs in
            if let selected = logs.first(where: { $0.id == proxyLogs.first }) {
                Button("Export") {
                    viewModel.exportRequestToTxt(request: selected)
                }
                Button("Mock Request") {
                    editViewModel.setupProxyLog(proxyLog: selected)
                    modalRouter.activeModal = .editMock
                }
            }
        }
        
    }
}

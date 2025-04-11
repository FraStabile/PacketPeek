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
    let logs: [ProxyLog] // Replace with your actual log type
    
    init(viewModel: HomeViewModel, logs: [ProxyLog]) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.logs = logs
    }
    
    var body: some View {
        Table(logs, selection: $viewModel.selectedLogID) {
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
    }
}

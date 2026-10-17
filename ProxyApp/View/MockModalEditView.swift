//
//  MockModalEditView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 15/04/25.
//
import SwiftUI

/// Single editor used both to create a mock from a captured request and to
/// edit an existing one (see `MockModalEditViewModel.isEditing`).
struct MockModalEditView: View {
    @EnvironmentObject var modalRouter: ModalRouter
    @StateObject var viewModel: MockModalEditViewModel
    init(viewModel: MockModalEditViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text(viewModel.isEditing ? "Edit Mock" : "Add Mock")
                .font(Typography.title)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                summaryRow("Method") {
                    MethodBadge(method: viewModel.log.method)
                }
                summaryRow("URL") {
                    Text(viewModel.log.url)
                        .font(Typography.bodyMono)
                        .foregroundStyle(Surface.secondaryText)
                        .lineLimit(4)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Divider()

            HStack(spacing: Spacing.xl) {
                field("Latency (ms)", placeholder: "e.g. 150", text: $viewModel.latency)
                field("Status code", placeholder: "e.g. 200", text: $viewModel.statusCode)
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text("Response body")
                        .font(Typography.headline)
                    Spacer()
                    if let warning = viewModel.jsonWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.caption)
                            .foregroundStyle(.orange)
                    }
                }
                TextEditor(text: $viewModel.response)
                    .font(Typography.bodyMono)
                    .frame(minHeight: 300)
                    .padding(Spacing.sm)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .stroke(viewModel.jsonWarning == nil ? Surface.separator : Color.orange)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            }

            Spacer()

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.body)
                    .foregroundStyle(.red)
            }

            HStack(spacing: Spacing.lg) {
                Button("Cancel", systemImage: "xmark") {
                    modalRouter.activeModal = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save", systemImage: "checkmark") {
                    Task {
                        // Keep the sheet open on failure so the error is visible.
                        if await viewModel.save() {
                            modalRouter.activeModal = nil
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isSaving)
            }
        }
        .padding(Spacing.xl)
    }

    private func summaryRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Typography.headline)
                .frame(width: 64, alignment: .leading)
            content()
        }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(Typography.headline)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Typography.bodyMono)
                .frame(width: 120)
        }
    }
}

#Preview {
    MockModalEditView(viewModel: MockModalEditViewModel())
        .environmentObject(ModalRouter())
}

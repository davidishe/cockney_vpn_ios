import Combine
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct LogView: View {
    let logs: [String]
    let isUploading: Bool
    let uploadErrorMessage: String?
    let onClear: () -> Void
    let onUpload: () -> Void
    let onRefresh: () -> Void
    let onDismissUploadError: () -> Void
    #if os(iOS)
    @State private var isSharing = false
    #endif

    public init(
        logs: [String],
        isUploading: Bool = false,
        uploadErrorMessage: String? = nil,
        onClear: @escaping () -> Void,
        onUpload: @escaping () -> Void = {},
        onRefresh: @escaping () -> Void = {},
        onDismissUploadError: @escaping () -> Void = {}
    ) {
        self.logs = logs
        self.isUploading = isUploading
        self.uploadErrorMessage = uploadErrorMessage
        self.onClear = onClear
        self.onUpload = onUpload
        self.onRefresh = onRefresh
        self.onDismissUploadError = onDismissUploadError
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Журнал", systemImage: "list.bullet.rectangle")
                #if os(iOS)
                    .font(.subheadline.weight(.semibold))
                #else
                    .font(.headline)
                #endif
                Spacer()
                Button(action: onRefresh) {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .disabled(isUploading)
                Button(action: copyLogs) {
                    Label("Копировать", systemImage: "doc.on.doc")
                }
                .disabled(logs.isEmpty || isUploading)
                #if os(iOS)
                Button {
                    isSharing = true
                } label: {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
                .disabled(logs.isEmpty || isUploading)
                #endif
                Button(action: onUpload) {
                    if isUploading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("На сервер", systemImage: "icloud.and.arrow.up")
                    }
                }
                .disabled(logs.isEmpty || isUploading)
                Button(action: onClear) {
                    Label("Очистить", systemImage: "trash")
                }
                .disabled(logs.isEmpty || isUploading)
            }
            .padding([.horizontal, .top])

            if let uploadErrorMessage, !uploadErrorMessage.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(uploadErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("OK", action: onDismissUploadError)
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if logs.isEmpty {
                            Text("Записей пока нет.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: logs.count) { count in
                    guard count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: onRefresh)
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            guard !isUploading else { return }
            onRefresh()
        }
        #if os(iOS)
        .font(.subheadline)
        .sheet(isPresented: $isSharing) {
            ActivityView(activityItems: [logsText])
        }
        #endif
    }

    private var logsText: String {
        logs.joined(separator: "\n")
    }

    private func copyLogs() {
        let text = logsText
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

#if os(iOS)
private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

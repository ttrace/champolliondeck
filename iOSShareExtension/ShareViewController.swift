import Social
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: SLComposeServiceViewController {
    override func isContentValid() -> Bool {
        true
    }

    override func didSelectPost() {
        Task { @MainActor in
            let shared = await composeSharedText()
            if !shared.isEmpty {
                SharedImportStore.savePendingText(shared)
                openHostApp(with: shared)
            }
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    override func configurationItems() -> [Any]! {
        []
    }

    private func composeSharedText() async -> String {
        var fragments: [String] = []

        let composerText = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !composerText.isEmpty {
            fragments.append(composerText)
        }

        let attachmentText = await collectAttachmentText()
        if !attachmentText.isEmpty {
            fragments.append(attachmentText)
        }

        return fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func collectAttachmentText() async -> String {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return ""
        }

        var fragments: [String] = []

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if let text = await loadText(from: provider) {
                    fragments.append(text)
                }
            }
        }

        return fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let text = await loadStringValue(provider: provider, typeIdentifier: UTType.fileURL.identifier)
        {
            return text
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let text = await loadStringValue(provider: provider, typeIdentifier: UTType.url.identifier)
        {
            return text
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadStringValue(provider: provider, typeIdentifier: UTType.plainText.identifier)
        {
            return text
        }

        return nil
    }

    private func loadStringValue(provider: NSItemProvider, typeIdentifier: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if let url = item as? URL {
                    if url.isFileURL, let fileText = Self.readTextFile(at: url) {
                        continuation.resume(returning: fileText)
                        return
                    }
                    continuation.resume(returning: url.absoluteString)
                    return
                }
                if let text = item as? String {
                    continuation.resume(returning: text)
                    return
                }
                if let nsURL = item as? NSURL {
                    if let url = nsURL as URL?, url.isFileURL, let fileText = Self.readTextFile(at: url) {
                        continuation.resume(returning: fileText)
                        return
                    }
                    continuation.resume(returning: nsURL.absoluteString)
                    return
                }
                if let attributed = item as? NSAttributedString {
                    continuation.resume(returning: attributed.string)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    nonisolated private static func readTextFile(at url: URL) -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        guard let data = try? Data(contentsOf: url) else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) {
            return String(utf8.prefix(10_000))
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return String(utf16.prefix(10_000))
        }
        if let shiftJIS = String(data: data, encoding: .shiftJIS) {
            return String(shiftJIS.prefix(10_000))
        }
        return nil
    }

    private func openHostApp(with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let capped = String(trimmed.prefix(1500))
        let encoded = capped.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = encoded.isEmpty
            ? "prebabellens://import-shared"
            : "prebabellens://import-shared?text=\(encoded)"
        guard let url = URL(string: urlString) else { return }
        extensionContext?.open(url, completionHandler: nil)
    }
}

import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum SharedImportStore {
    enum PendingImport {
        case text(String)
        case imageFile(URL)
    }

    private enum PendingImportKind: String {
        case text
        case image
    }

    static let appGroupID = "group.com.ttrace.prebabellens"
    private static let pendingTextKey = "pendingSharedText"
    private static let pendingDateKey = "pendingSharedDate"
    private static let pendingImportKindKey = "pendingSharedImportKind"
    private static let pendingImageRelativePathKey = "pendingSharedImageRelativePath"
    private static let sharedImportsDirectoryName = "SharedImports"
    #if canImport(UIKit)
    private static let pasteboardName = UIPasteboard.Name("com.ttrace.prebabellens.sharedimport")
    #endif

    static func savePendingText(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if let defaults = UserDefaults(suiteName: appGroupID) {
            clearPendingImage(defaults: defaults)
            defaults.set(normalized, forKey: pendingTextKey)
            defaults.set(Date(), forKey: pendingDateKey)
            defaults.set(PendingImportKind.text.rawValue, forKey: pendingImportKindKey)
        }

        #if canImport(UIKit)
        if let pasteboard = UIPasteboard(name: pasteboardName, create: true) {
            pasteboard.string = normalized
        }
        #endif
    }

    static func savePendingImageData(_ data: Data, fileExtension: String? = nil) -> Bool {
        guard !data.isEmpty else { return false }
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return false }
        guard let destinationURL = makeSharedImageURL(fileExtension: fileExtension) else { return false }

        do {
            let directoryURL = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            return false
        }

        clearPendingImage(defaults: defaults)
        defaults.removeObject(forKey: pendingTextKey)
        defaults.set(Date(), forKey: pendingDateKey)
        defaults.set(PendingImportKind.image.rawValue, forKey: pendingImportKindKey)
        defaults.set(destinationURL.lastPathComponent, forKey: pendingImageRelativePathKey)

        #if canImport(UIKit)
        if let pasteboard = UIPasteboard(name: pasteboardName, create: true) {
            pasteboard.string = nil
        }
        #endif
        return true
    }

    static func consumePendingImport() -> PendingImport? {
        if let defaults = UserDefaults(suiteName: appGroupID) {
            let kind = PendingImportKind(rawValue: defaults.string(forKey: pendingImportKindKey) ?? "")

            if kind == .image,
               let relativePath = defaults.string(forKey: pendingImageRelativePathKey),
               let imageURL = sharedImportsDirectoryURL()?.appendingPathComponent(relativePath),
               FileManager.default.fileExists(atPath: imageURL.path)
            {
                defaults.removeObject(forKey: pendingImportKindKey)
                defaults.removeObject(forKey: pendingImageRelativePathKey)
                defaults.removeObject(forKey: pendingDateKey)
                return .imageFile(imageURL)
            }

            if let text = defaults.string(forKey: pendingTextKey) {
                defaults.removeObject(forKey: pendingTextKey)
                defaults.removeObject(forKey: pendingImportKindKey)
                defaults.removeObject(forKey: pendingDateKey)
                return .text(text)
            }
        }

        #if canImport(UIKit)
        if let pasteboard = UIPasteboard(name: pasteboardName, create: false),
           let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            pasteboard.string = nil
            return .text(text)
        }
        #endif

        return nil
    }

    static func consumePendingText() -> String? {
        if let defaults = UserDefaults(suiteName: appGroupID) {
            let kind = PendingImportKind(rawValue: defaults.string(forKey: pendingImportKindKey) ?? "")
            if kind == .image {
                return nil
            }

            if let text = defaults.string(forKey: pendingTextKey) {
                defaults.removeObject(forKey: pendingTextKey)
                defaults.removeObject(forKey: pendingImportKindKey)
                defaults.removeObject(forKey: pendingDateKey)
                return text
            }
        }

        #if canImport(UIKit)
        if let pasteboard = UIPasteboard(name: pasteboardName, create: false),
           let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            pasteboard.string = nil
            return text
        }
        #endif

        return nil
    }

    private static func clearPendingImage(defaults: UserDefaults) {
        if let relativePath = defaults.string(forKey: pendingImageRelativePathKey),
           let imageURL = sharedImportsDirectoryURL()?.appendingPathComponent(relativePath)
        {
            try? FileManager.default.removeItem(at: imageURL)
        }
        defaults.removeObject(forKey: pendingImageRelativePathKey)
    }

    private static func makeSharedImageURL(fileExtension: String?) -> URL? {
        guard let directoryURL = sharedImportsDirectoryURL() else { return nil }
        let sanitizedExtension: String = {
            let ext = (fileExtension ?? "jpg")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return ext.isEmpty ? "jpg" : ext
        }()
        let filename = "\(UUID().uuidString).\(sanitizedExtension)"
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private static func sharedImportsDirectoryURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(sharedImportsDirectoryName, isDirectory: true)
    }
}

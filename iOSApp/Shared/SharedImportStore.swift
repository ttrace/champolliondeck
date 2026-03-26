import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum SharedImportStore {
    static let appGroupID = "group.com.ttrace.prebabellens"
    private static let pendingTextKey = "pendingSharedText"
    private static let pendingDateKey = "pendingSharedDate"
    #if canImport(UIKit)
    private static let pasteboardName = UIPasteboard.Name("com.ttrace.prebabellens.sharedimport")
    #endif

    static func savePendingText(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if let defaults = UserDefaults(suiteName: appGroupID) {
            defaults.set(normalized, forKey: pendingTextKey)
            defaults.set(Date(), forKey: pendingDateKey)
        }

        #if canImport(UIKit)
        if let pasteboard = UIPasteboard(name: pasteboardName, create: true) {
            pasteboard.string = normalized
        }
        #endif
    }

    static func consumePendingText() -> String? {
        if let defaults = UserDefaults(suiteName: appGroupID),
           let text = defaults.string(forKey: pendingTextKey)
        {
            defaults.removeObject(forKey: pendingTextKey)
            defaults.removeObject(forKey: pendingDateKey)
            return text
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
}

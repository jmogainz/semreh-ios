import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum AppIconChoice: String, CaseIterable, Identifiable {
    case system

    var id: String { rawValue }

    var title: String {
        String(localized: "Semreh")
    }

    var subtitle: String {
        "Canonical Semreh icon"
    }

    var alternateIconName: String? { nil }

    var previewImageName: String? { "SemrehAppIcon" }

    static func resolved(from alternateIconName: String?) -> AppIconChoice {
        .system
    }

    #if canImport(UIKit)
    @MainActor
    static var current: AppIconChoice { .system }
    #endif
}

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Platform facts stamped into analytics event context and condition context.
enum DeviceContext {
    /// `ios` on iPhone/iPad, `macos` when running the package on macOS (tests).
    static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }

    static var osVersion: String? {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    /// BCP-47 language tag, e.g. `en-US`.
    static var localeTag: String? {
        Locale.preferredLanguages.first ?? Locale.current.identifier
    }

    /// Bare language code, e.g. `en` — used for flow locale resolution.
    static var languageCode: String? {
        if let tag = Locale.preferredLanguages.first {
            return String(tag.prefix(while: { $0 != "-" && $0 != "_" })).lowercased()
        }
        return Locale.current.languageCode
    }
}

import Foundation

enum AppConfig {
    static let privacyPolicyURL = URL(staticString: "https://github.com/jmogainz/semreh-ios/blob/master/PRIVACY.md")
    static let supportURL = URL(staticString: "https://github.com/jmogainz/semreh-ios/issues")
}

extension URL {
    init(staticString string: StaticString) {
        let value = string.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid static URL literal: \(value)")
        }
        self = url
    }
}

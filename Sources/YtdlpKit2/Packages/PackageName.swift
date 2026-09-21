import Foundation

enum PackageName {
    static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(
            of: "[-_.]+", with: "-", options: .regularExpression
        )
    }
}

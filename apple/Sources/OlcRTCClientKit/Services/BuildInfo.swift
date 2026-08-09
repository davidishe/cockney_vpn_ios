import Foundation

/// Identifies the running binary in diagnostics. The bundle version alone does not
/// change between local Xcode builds, so the executable timestamp is what actually
/// tells one build from the next.
public enum BuildInfo {
    public static var summary: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(short)(\(build)) built=\(builtAt) \(configuration)"
    }

    private static var builtAt: String {
        guard let executable = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let modified = attributes[.modificationDate] as? Date
        else {
            return "unknown"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: modified)
    }

    private static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }
}

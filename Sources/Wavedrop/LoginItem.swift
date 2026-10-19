import Foundation

/// Per-user LaunchAgent that starts Wavedrop hidden (`--background`) at login.
/// Only installed for the copy in /Applications, so development builds never register themselves.
enum LoginItem {
    static let label = "local.wavedrop.visualizer.login"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func sync(enabled: Bool) {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasPrefix("/Applications/"), let exe = Bundle.main.executablePath else { return }
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe, "--background"],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
            if (try? Data(contentsOf: plistURL)) == data { return }
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: plistURL)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}

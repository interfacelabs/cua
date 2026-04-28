import AppKit
import Foundation

public struct BrowserTabInfo: Sendable, Codable, Hashable {
    public let bundleId: String
    public let pid: Int32
    public let browserWindowIndex: Int
    public let browserWindowId: Int?
    public let browserWindowBounds: WindowBounds?
    public let browserWindowTitle: String
    public let tabIndex: Int
    public let tabId: Int?
    public let title: String
    public let url: String
    public let isActive: Bool
    public let owningWindowId: Int?

    public init(
        bundleId: String,
        pid: Int32,
        browserWindowIndex: Int,
        browserWindowId: Int?,
        browserWindowBounds: WindowBounds?,
        browserWindowTitle: String,
        tabIndex: Int,
        tabId: Int?,
        title: String,
        url: String,
        isActive: Bool,
        owningWindowId: Int?
    ) {
        self.bundleId = bundleId
        self.pid = pid
        self.browserWindowIndex = browserWindowIndex
        self.browserWindowId = browserWindowId
        self.browserWindowBounds = browserWindowBounds
        self.browserWindowTitle = browserWindowTitle
        self.tabIndex = tabIndex
        self.tabId = tabId
        self.title = title
        self.url = url
        self.isActive = isActive
        self.owningWindowId = owningWindowId
    }

    private enum CodingKeys: String, CodingKey {
        case bundleId = "bundle_id"
        case pid
        case browserWindowIndex = "browser_window_index"
        case browserWindowId = "browser_window_id"
        case browserWindowBounds = "browser_window_bounds"
        case browserWindowTitle = "browser_window_title"
        case tabIndex = "tab_index"
        case tabId = "tab_id"
        case title
        case url
        case isActive = "is_active"
        case owningWindowId = "owning_window_id"
    }
}

public enum BrowserTabEnumerator {
    public static func supports(bundleId: String) -> Bool {
        browserAppName(bundleId: bundleId) != nil
    }

    public static func tabs(bundleId: String, pid: Int32) async -> [BrowserTabInfo] {
        guard let appName = browserAppName(bundleId: bundleId) else { return [] }
        let windows = WindowEnumerator.allWindows()
            .filter { $0.pid == pid && $0.layer == 0 }
        let script = appleScript(appName: appName, safari: bundleId == "com.apple.Safari")
        guard let output = try? await runAppleScript(script) else { return [] }

        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                parseLine(
                    String(line),
                    bundleId: bundleId,
                    pid: pid,
                    windows: windows
                )
            }
    }

    private static func browserAppName(bundleId: String) -> String? {
        switch bundleId {
        case "com.google.Chrome": return "Google Chrome"
        case "com.brave.Browser": return "Brave Browser"
        case "com.microsoft.edgemac": return "Microsoft Edge"
        case "com.apple.Safari": return "Safari"
        default: return nil
        }
    }

    private static func appleScript(appName: String, safari: Bool) -> String {
        if safari {
            return """
            tell application "\(appName)"
              set sep to ASCII character 9
              set out to ""
              repeat with wi from 1 to count of windows
                set w to window wi
                set b to bounds of w
                set activeIndex to 1
                try
                  set activeTab to current tab of w
                  repeat with ti from 1 to count of tabs of w
                    if tab ti of w is activeTab then set activeIndex to ti
                  end repeat
                end try
                repeat with ti from 1 to count of tabs of w
                  set t to tab ti of w
                  set tabTitle to ""
                  set tabURL to ""
                  try
                    set tabTitle to name of t
                  end try
                  try
                    set tabURL to URL of t
                  end try
                  set out to out & wi & sep & "" & sep & ti & sep & "" & sep & (item 1 of b) & sep & (item 2 of b) & sep & (item 3 of b) & sep & (item 4 of b) & sep & (name of w) & sep & tabTitle & sep & tabURL & sep & ((ti = activeIndex) as text) & linefeed
                end repeat
              end repeat
              return out
            end tell
            """
        }

        return """
        tell application "\(appName)"
          set sep to ASCII character 9
          set out to ""
          repeat with wi from 1 to count of windows
            set w to window wi
            set b to bounds of w
            set activeIndex to active tab index of w
            repeat with ti from 1 to count of tabs of w
              set t to tab ti of w
              set out to out & wi & sep & ((id of w) as text) & sep & ti & sep & ((id of t) as text) & sep & (item 1 of b) & sep & (item 2 of b) & sep & (item 3 of b) & sep & (item 4 of b) & sep & (name of w) & sep & (title of t) & sep & (URL of t) & sep & ((ti = activeIndex) as text) & linefeed
            end repeat
          end repeat
          return out
        end tell
        """
    }

    private static func parseLine(
        _ line: String,
        bundleId: String,
        pid: Int32,
        windows: [WindowInfo]
    ) -> BrowserTabInfo? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 12,
              let browserWindowIndex = Int(parts[0]),
              let tabIndex = Int(parts[2])
        else { return nil }

        let browserWindowId = Int(parts[1])
        let tabId = Int(parts[3])
        let browserWindowBounds = parseBounds(
            left: parts[4],
            top: parts[5],
            right: parts[6],
            bottom: parts[7]
        )
        let browserWindowTitle = parts[8]
        let title = parts[9]
        let url = parts[10]
        let isActive = parts[11].lowercased() == "true"
        let owningWindowId = matchWindowId(
            browserWindowTitle: browserWindowTitle,
            activeTabTitle: isActive ? title : nil,
            browserWindowBounds: browserWindowBounds,
            windows: windows
        )

        return BrowserTabInfo(
            bundleId: bundleId,
            pid: pid,
            browserWindowIndex: browserWindowIndex,
            browserWindowId: browserWindowId,
            browserWindowBounds: browserWindowBounds,
            browserWindowTitle: browserWindowTitle,
            tabIndex: tabIndex,
            tabId: tabId,
            title: title,
            url: url,
            isActive: isActive,
            owningWindowId: owningWindowId
        )
    }

    private static func matchWindowId(
        browserWindowTitle: String,
        activeTabTitle: String?,
        browserWindowBounds: WindowBounds?,
        windows: [WindowInfo]
    ) -> Int? {
        if let browserWindowBounds {
            let boundMatches = windows.filter {
                boundsApproximatelyEqual($0.bounds, browserWindowBounds)
            }
            if boundMatches.count == 1 { return boundMatches[0].id }

            let titledBoundMatches = boundMatches.filter {
                titleMatches(windowTitle: $0.name, browserTitle: browserWindowTitle)
            }
            if titledBoundMatches.count == 1 { return titledBoundMatches[0].id }
        }

        let titles = [browserWindowTitle, activeTabTitle ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for title in titles {
            let exact = windows.filter { $0.name == title }
            if exact.count == 1 { return exact[0].id }

            let contains = windows.filter { window in
                window.name.contains(title) || title.contains(window.name)
            }
            if contains.count == 1 { return contains[0].id }
        }
        return nil
    }

    private static func parseBounds(
        left: String,
        top: String,
        right: String,
        bottom: String
    ) -> WindowBounds? {
        guard let x = Double(left),
              let y = Double(top),
              let right = Double(right),
              let bottom = Double(bottom)
        else { return nil }
        return WindowBounds(
            x: x,
            y: y,
            width: max(0, right - x),
            height: max(0, bottom - y)
        )
    }

    private static func boundsApproximatelyEqual(
        _ lhs: WindowBounds,
        _ rhs: WindowBounds
    ) -> Bool {
        abs(lhs.x - rhs.x) <= 4
            && abs(lhs.y - rhs.y) <= 4
            && abs(lhs.width - rhs.width) <= 8
            && abs(lhs.height - rhs.height) <= 8
    }

    private static func titleMatches(
        windowTitle: String,
        browserTitle: String
    ) -> Bool {
        let window = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let browser = browserTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty, !browser.isEmpty else { return false }
        return window == browser || window.contains(browser) || browser.contains(window)
    }

    private static func runAppleScript(_ script: String) async throws -> String {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".applescript")
        try script.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = [tmpURL.path]
            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr
            proc.terminationHandler = { p in
                let out = String(
                    data: stdout.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let err = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                if p.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "BrowserTabEnumerator",
                            code: Int(p.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: err]
                        )
                    )
                }
            }
            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

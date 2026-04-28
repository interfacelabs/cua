import AppKit
import CuaDriverCore
import Foundation
import MCP

public enum ListBrowserTabsTool {
    public static let handler = ToolHandler(
        tool: Tool(
            name: "list_browser_tabs",
            description: """
                List browser tabs for supported macOS browsers and attach
                each tab to its owning WindowServer window when possible.

                Supported browsers: Chrome, Brave, Edge, Safari. The result
                includes tab_id, title, URL, active state, browser window
                index/id, owning window_id, and owning window_uid. Use this
                with list_windows/diff_windows to keep browser tasks pinned
                to the intended tab/window instead of drifting between same-
                app windows.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "pid": [
                        "type": "integer",
                        "description": "Optional browser pid filter.",
                    ],
                    "bundle_id": [
                        "type": "string",
                        "description": "Optional browser bundle id filter, e.g. com.google.Chrome.",
                    ],
                ],
                "additionalProperties": false,
            ],
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: false
            )
        ),
        invoke: { arguments in
            let pidFilter = arguments?["pid"]?.intValue.flatMap { Int32(exactly: $0) }
            let bundleFilter = arguments?["bundle_id"]?.stringValue
            let apps = await MainActor.run {
                NSWorkspace.shared.runningApplications.compactMap { app -> (Int32, String)? in
                    guard let bundleId = app.bundleIdentifier,
                          BrowserTabEnumerator.supports(bundleId: bundleId)
                    else { return nil }
                    let pid = app.processIdentifier
                    if let pidFilter, pid != pidFilter { return nil }
                    if let bundleFilter, bundleId != bundleFilter { return nil }
                    return (pid, bundleId)
                }
            }

            var tabs: [TabRow] = []
            for (pid, bundleId) in apps {
                let rawTabs = await BrowserTabEnumerator.tabs(bundleId: bundleId, pid: pid)
                let windows = WindowEnumerator.allWindows().filter {
                    $0.pid == pid && $0.layer == 0
                }
                let identities = await WindowIdentityStore.shared.metadata(for: windows)
                tabs.append(contentsOf: rawTabs.map { tab in
                    TabRow(
                        tab: tab,
                        owningWindowUID: tab.owningWindowId.flatMap {
                            identities[$0]?.windowUID
                        }
                    )
                })
            }

            let output = Output(tabs: tabs)
            let text = "✅ Found \(tabs.count) browser tab(s)."
            let content: [Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
            if let result = try? CallTool.Result(content: content, structuredContent: output) {
                return result
            }
            return CallTool.Result(content: content)
        }
    )

    struct Output: Codable, Sendable {
        let tabs: [TabRow]
    }

    struct TabRow: Codable, Sendable {
        let bundleId: String
        let pid: Int32
        let browserWindowIndex: Int
        let browserWindowId: Int?
        let browserWindowBounds: WindowBounds?
        let browserWindowTitle: String
        let tabIndex: Int
        let tabId: Int?
        let title: String
        let url: String
        let isActive: Bool
        let owningWindowId: Int?
        let owningWindowUID: String?

        init(tab: BrowserTabInfo, owningWindowUID: String?) {
            self.bundleId = tab.bundleId
            self.pid = tab.pid
            self.browserWindowIndex = tab.browserWindowIndex
            self.browserWindowId = tab.browserWindowId
            self.browserWindowBounds = tab.browserWindowBounds
            self.browserWindowTitle = tab.browserWindowTitle
            self.tabIndex = tab.tabIndex
            self.tabId = tab.tabId
            self.title = tab.title
            self.url = tab.url
            self.isActive = tab.isActive
            self.owningWindowId = tab.owningWindowId
            self.owningWindowUID = owningWindowUID
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
            case owningWindowUID = "owning_window_uid"
        }
    }
}

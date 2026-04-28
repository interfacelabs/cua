import CuaDriverCore
import Foundation
import MCP

public enum DiffWindowsTool {
    public static let handler = ToolHandler(
        tool: Tool(
            name: "diff_windows",
            description: """
                Diff WindowServer windows between two snapshots.

                Use `list_windows` before an action and keep its
                `snapshot_token`, then call `diff_windows({before_token})`
                after the action. The tool captures the current window set,
                stores it as `after_token`, and returns created, destroyed,
                and changed windows keyed by stable window_uid when possible.

                This is intended for robust window/document targeting after
                open_url, file pickers, modal creation, document opening, or
                apps that recreate windows.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "before_token": [
                        "type": "string",
                        "description": "snapshot_token previously returned by list_windows or diff_windows.",
                    ],
                    "after_token": [
                        "type": "string",
                        "description": "Optional existing snapshot_token to use as the after side. When omitted, the current window set is captured.",
                    ],
                    "pid": [
                        "type": "integer",
                        "description": "Optional pid filter for the after snapshot when after_token is omitted.",
                    ],
                    "on_screen_only": [
                        "type": "boolean",
                        "description": "Optional after-snapshot visibility filter. Default false.",
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
            guard let beforeToken = arguments?["before_token"]?.stringValue,
                  !beforeToken.isEmpty
            else {
                let current = await captureRows(arguments: arguments)
                let token = await WindowSnapshotStore.shared.store(current)
                return outputResult(
                    Output(
                        beforeToken: nil,
                        afterToken: token,
                        created: [],
                        destroyed: [],
                        changed: [],
                        note:
                            "No before_token was supplied; captured current windows as after_token. Call list_windows first or pass this token as before_token later."
                    )
                )
            }

            guard let before = await WindowSnapshotStore.shared.rows(for: beforeToken) else {
                return StructuredToolError.result(
                    code: "unknown_snapshot_token",
                    message: "Unknown before_token \(beforeToken). Snapshot tokens are daemon-local and expire after recent history fills.",
                    suggestedRecovery: "Call list_windows again, then retry diff_windows with the new snapshot_token."
                )
            }

            let after: [ListWindowsTool.Row]
            let afterToken: String
            if let existingAfterToken = arguments?["after_token"]?.stringValue,
               let existingRows = await WindowSnapshotStore.shared.rows(for: existingAfterToken)
            {
                after = existingRows
                afterToken = existingAfterToken
            } else {
                after = await captureRows(arguments: arguments)
                afterToken = await WindowSnapshotStore.shared.store(after)
            }

            return outputResult(
                Output(
                    beforeToken: beforeToken,
                    afterToken: afterToken,
                    created: created(before: before, after: after),
                    destroyed: destroyed(before: before, after: after),
                    changed: changed(before: before, after: after),
                    note: nil
                )
            )
        }
    )

    struct Output: Codable, Sendable {
        let beforeToken: String?
        let afterToken: String
        let created: [ListWindowsTool.Row]
        let destroyed: [ListWindowsTool.Row]
        let changed: [WindowChange]
        let note: String?

        private enum CodingKeys: String, CodingKey {
            case beforeToken = "before_token"
            case afterToken = "after_token"
            case created
            case destroyed
            case changed
            case note
        }
    }

    struct WindowChange: Codable, Sendable {
        let before: ListWindowsTool.Row
        let after: ListWindowsTool.Row
        let changes: [String]
    }

    private static func captureRows(arguments: [String: Value]?) async -> [ListWindowsTool.Row] {
        let pidFilter = arguments?["pid"]?.intValue.flatMap { Int32(exactly: $0) }
        let onScreenOnly = arguments?["on_screen_only"]?.boolValue ?? false
        let raw = onScreenOnly ? WindowEnumerator.visibleWindows() : WindowEnumerator.allWindows()
        let windows = raw
            .filter { $0.layer == 0 }
            .filter { info in
                guard let pidFilter else { return true }
                return info.pid == pidFilter
            }
        let currentSpaceID = SpaceMigrator.currentSpaceID()
        let identities = await WindowIdentityStore.shared.metadata(for: windows)
        let axByPid = Dictionary(
            uniqueKeysWithValues: Set(windows.map(\.pid)).map {
                ($0, WindowAXMetadataReader.metadata(forPid: $0))
            }
        )
        return windows.map {
            ListWindowsTool.row(
                for: $0,
                currentSpaceID: currentSpaceID,
                identity: identities[$0.id],
                axMetadata: axByPid[$0.pid]?[$0.id]
            )
        }
    }

    private static func created(
        before: [ListWindowsTool.Row],
        after: [ListWindowsTool.Row]
    ) -> [ListWindowsTool.Row] {
        let beforeKeys = Set(before.map(key))
        return after.filter { !beforeKeys.contains(key($0)) }
    }

    private static func destroyed(
        before: [ListWindowsTool.Row],
        after: [ListWindowsTool.Row]
    ) -> [ListWindowsTool.Row] {
        let afterKeys = Set(after.map(key))
        return before.filter { !afterKeys.contains(key($0)) }
    }

    private static func changed(
        before: [ListWindowsTool.Row],
        after: [ListWindowsTool.Row]
    ) -> [WindowChange] {
        let beforeByKey = Dictionary(uniqueKeysWithValues: before.map { (key($0), $0) })
        return after.compactMap { afterRow in
            guard let beforeRow = beforeByKey[key(afterRow)] else { return nil }
            var changes: [String] = []
            if beforeRow.title != afterRow.title { changes.append("title") }
            if beforeRow.bounds != afterRow.bounds { changes.append("bounds") }
            if beforeRow.zIndex != afterRow.zIndex { changes.append("z_index") }
            if beforeRow.isOnScreen != afterRow.isOnScreen { changes.append("is_on_screen") }
            if beforeRow.onCurrentSpace != afterRow.onCurrentSpace { changes.append("on_current_space") }
            if beforeRow.spaceIds != afterRow.spaceIds { changes.append("space_ids") }
            if beforeRow.isMain != afterRow.isMain { changes.append("is_main") }
            if beforeRow.isFocused != afterRow.isFocused { changes.append("is_focused") }
            if changes.isEmpty { return nil }
            return WindowChange(before: beforeRow, after: afterRow, changes: changes)
        }
    }

    private static func key(_ row: ListWindowsTool.Row) -> String {
        row.windowUID ?? "\(row.pid):\(row.windowId)"
    }

    private static func outputResult(_ output: Output) -> CallTool.Result {
        let summary =
            "created=\(output.created.count), destroyed=\(output.destroyed.count), changed=\(output.changed.count), after_token=\(output.afterToken)"
        let content: [Tool.Content] = [.text(text: summary, annotations: nil, _meta: nil)]
        if let result = try? CallTool.Result(content: content, structuredContent: output) {
            return result
        }
        return CallTool.Result(content: content)
    }
}

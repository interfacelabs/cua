import CuaDriverCore
import Foundation
import MCP

enum WindowLeaseValidation {
    case success(ListWindowsTool.Row)
    case failure(CallTool.Result)
}

enum WindowLeaseGuard {
    static func validate(
        pid: Int32,
        windowId: UInt32?,
        windowUID: String? = nil,
        expectedTitle: String? = nil,
        purpose: String = "act on the target window"
    ) async -> WindowLeaseValidation {
        let raw = WindowEnumerator.allWindows().filter { $0.layer == 0 }
        let currentSpaceID = SpaceMigrator.currentSpaceID()
        let identities = await WindowIdentityStore.shared.metadata(for: raw)
        let axByPid = Dictionary(
            uniqueKeysWithValues: Set(raw.map(\.pid)).map {
                ($0, WindowAXMetadataReader.metadata(forPid: $0))
            }
        )
        let rows = raw.map {
            ListWindowsTool.row(
                for: $0,
                currentSpaceID: currentSpaceID,
                identity: identities[$0.id],
                axMetadata: axByPid[$0.pid]?[$0.id]
            )
        }
        let samePid = rows.filter { $0.pid == pid }

        if let windowId {
            if let row = rows.first(where: { $0.windowId == Int(windowId) }) {
                if row.pid == pid {
                    if let windowUID, row.windowUID != windowUID {
                        return .failure(
                            StructuredToolError.result(
                                code: "window_uid_mismatch",
                                message:
                                    "window_id \(windowId) is present for pid \(pid), but its window_uid changed. Refusing to reuse a possibly recreated window.",
                                requested: WindowRequest(
                                    pid: pid,
                                    windowId: Int(windowId),
                                    windowUID: windowUID
                                ),
                                knownWindows: samePid,
                                possibleReplacements: replacements(
                                    from: samePid,
                                    expectedTitle: expectedTitle
                                ),
                                suggestedRecovery:
                                    "Call list_windows for this pid, then reacquire only if exactly one candidate matches the task/document fingerprint."
                            )
                        )
                    }
                    return .success(row)
                }
                return .failure(
                    StructuredToolError.result(
                        code: "window_pid_mismatch",
                        message:
                            "window_id \(windowId) belongs to pid \(row.pid), not pid \(pid). Refusing to \(purpose).",
                        requested: WindowRequest(
                            pid: pid,
                            windowId: Int(windowId),
                            windowUID: windowUID
                        ),
                        actualOwnerPid: row.pid,
                        knownWindows: samePid,
                        possibleReplacements: replacements(
                            from: samePid,
                            expectedTitle: expectedTitle
                        ),
                        suggestedRecovery:
                            "Use a window_id returned for the requested pid. Do not silently switch to another same-app window."
                    )
                )
            }
            return .failure(
                StructuredToolError.result(
                    code: "window_not_found",
                    message:
                        "No window with window_id \(windowId) exists. Refusing to \(purpose).",
                    requested: WindowRequest(
                        pid: pid,
                        windowId: Int(windowId),
                        windowUID: windowUID
                    ),
                    knownWindows: samePid,
                    possibleReplacements: replacements(
                        from: samePid,
                        expectedTitle: expectedTitle
                    ),
                    suggestedRecovery:
                        "Revalidate the task window lease. Reacquire only if exactly one candidate matches the previous title/document/url/display fingerprint."
                )
            )
        }

        let usable = samePid.filter(isUsableWindow)
        let candidates = usable.isEmpty ? samePid : usable
        if candidates.count == 1, let only = candidates.first {
            return .success(only)
        }
        if candidates.isEmpty {
            return .failure(
                StructuredToolError.result(
                    code: "no_window_for_pid",
                    message:
                        "pid \(pid) has no layer-0 windows. Refusing to \(purpose).",
                    requested: WindowRequest(
                        pid: pid,
                        windowId: nil,
                        windowUID: windowUID
                    ),
                    knownWindows: samePid,
                    suggestedRecovery:
                        "Launch or reopen the target app/window, then call list_windows and pass the selected window_id."
                )
            )
        }
        return .failure(
            StructuredToolError.result(
                code: "ambiguous_window_target",
                message:
                    "pid \(pid) has \(candidates.count) plausible windows. Pass window_id/window_uid so cua-driver does not choose the wrong window.",
                requested: WindowRequest(
                    pid: pid,
                    windowId: nil,
                    windowUID: windowUID
                ),
                knownWindows: samePid,
                possibleReplacements: candidates,
                suggestedRecovery:
                    "Call list_windows, choose the intended task window using title/document/url/display metadata, and retry with window_id."
            )
        )
    }

    private static func replacements(
        from rows: [ListWindowsTool.Row],
        expectedTitle: String?
    ) -> [ListWindowsTool.Row] {
        if let expectedTitle {
            let needle = expectedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !needle.isEmpty {
                let matches = rows.filter {
                    $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == needle
                }
                if !matches.isEmpty { return matches }
            }
        }
        let usable = rows.filter(isUsableWindow)
        if usable.count == 1 { return usable }
        return rows.count == 1 ? rows : []
    }

    private static func isUsableWindow(_ row: ListWindowsTool.Row) -> Bool {
        row.bounds.width > 1 && row.bounds.height > 1
    }
}

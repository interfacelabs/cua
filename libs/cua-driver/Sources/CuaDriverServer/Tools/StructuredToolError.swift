import Foundation
import MCP

struct WindowRequest: Codable, Sendable {
    let pid: Int32?
    let windowId: Int?
    let windowUID: String?

    private enum CodingKeys: String, CodingKey {
        case pid
        case windowId = "window_id"
        case windowUID = "window_uid"
    }
}

struct StructuredToolFailure: Codable, Sendable {
    let error: String
    let message: String
    let requested: WindowRequest?
    let actualOwnerPid: Int32?
    let knownWindows: [ListWindowsTool.Row]
    let possibleReplacements: [ListWindowsTool.Row]
    let suggestedRecovery: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case message
        case requested
        case actualOwnerPid = "actual_owner_pid"
        case knownWindows = "known_windows"
        case possibleReplacements = "possible_replacements"
        case suggestedRecovery = "suggested_recovery"
    }
}

enum StructuredToolError {
    static func result(
        code: String,
        message: String,
        requested: WindowRequest? = nil,
        actualOwnerPid: Int32? = nil,
        knownWindows: [ListWindowsTool.Row] = [],
        possibleReplacements: [ListWindowsTool.Row] = [],
        suggestedRecovery: String? = nil
    ) -> CallTool.Result {
        let payload = StructuredToolFailure(
            error: code,
            message: message,
            requested: requested,
            actualOwnerPid: actualOwnerPid,
            knownWindows: knownWindows,
            possibleReplacements: possibleReplacements,
            suggestedRecovery: suggestedRecovery
        )
        let text = encode(payload) ?? message
        if let result = try? CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: payload,
            isError: true
        ) {
            return result
        }
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private static func encode(_ payload: StructuredToolFailure) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

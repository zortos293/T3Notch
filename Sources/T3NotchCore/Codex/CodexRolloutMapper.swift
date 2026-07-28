import Foundation

/// Everything a rollout file says about one Codex session, in the shapes the
/// notch's derivations already consume.
public struct CodexSessionState: Sendable, Equatable {
    public var sessionId: String
    public var cwd: String?
    public var branch: String?
    public var model: String?
    public var title: String?
    public var currentTurnId: String?
    public var latestTurn: LatestTurn?
    public var status: String
    public var startedAt: String?
    public var updatedAt: String?
    public var settledAt: String?
    public var activities: [ThreadActivity]

    public init(sessionId: String) {
        self.sessionId = sessionId
        self.status = "idle"
        self.activities = []
    }
}

/// Folds Codex rollout lines into `CodexSessionState`. Pure: one line in, state
/// change out, no IO. Unknown line and payload types are skipped, never fatal —
/// the rollout format tracks the CLI version, not this app.
public struct CodexRolloutMapper: Sendable {
    private struct PendingCall: Sendable {
        let summary: String
        let itemType: String
        let detail: String?
    }

    /// Activities the notch never shows more than a handful of, kept bounded for
    /// long sessions. The newest plan and context rows survive trimming.
    private static let activityCap = 300

    public private(set) var state: CodexSessionState
    private var sequence = 0
    private var pendingCalls: [String: PendingCall] = [:]

    public init(sessionId: String) {
        self.state = CodexSessionState(sessionId: sessionId)
    }

    /// Returns whether the line moved the session state.
    @discardableResult
    public mutating func ingest(line: Data) -> Bool {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line) else { return false }
        return ingest(value)
    }

    @discardableResult
    public mutating func ingest(_ line: JSONValue) -> Bool {
        guard let type = line["type"]?.stringValue, let payload = line["payload"] else {
            return false
        }
        let timestamp = line["timestamp"]?.stringValue ?? Self.isoNow()
        let before = state

        switch type {
        case "session_meta":
            applySessionMeta(payload, timestamp: timestamp)
        case "turn_context":
            applyTurnContext(payload)
        case "event_msg":
            applyEventMessage(payload, timestamp: timestamp)
        case "response_item":
            applyResponseItem(payload, timestamp: timestamp)
        default:
            break
        }

        if state != before {
            state.updatedAt = timestamp
            return true
        }
        return false
    }

    // MARK: - Line families

    private mutating func applySessionMeta(_ payload: JSONValue, timestamp: String) {
        if let id = payload["id"]?.stringValue, !id.isEmpty {
            state.sessionId = id
        }
        state.cwd = payload["cwd"]?.stringValue ?? state.cwd
        state.branch = payload["git"]?["branch"]?.stringValue ?? state.branch
        state.startedAt = state.startedAt ?? payload["timestamp"]?.stringValue ?? timestamp
    }

    private mutating func applyTurnContext(_ payload: JSONValue) {
        state.currentTurnId = payload["turn_id"]?.stringValue ?? state.currentTurnId
        state.model = payload["model"]?.stringValue ?? state.model
        state.cwd = payload["cwd"]?.stringValue ?? state.cwd
    }

    private mutating func applyEventMessage(_ payload: JSONValue, timestamp: String) {
        switch payload["type"]?.stringValue {
        case "task_started":
            let turnId = payload["turn_id"]?.stringValue ?? state.currentTurnId ?? state.sessionId
            state.currentTurnId = turnId
            state.latestTurn = LatestTurn(turnId: turnId, state: "running", startedAt: timestamp)
            state.status = "running"
            state.settledAt = nil
        case "task_complete":
            let turnId = payload["turn_id"]?.stringValue ?? state.currentTurnId ?? state.sessionId
            state.latestTurn = LatestTurn(
                turnId: turnId,
                state: "completed",
                startedAt: state.latestTurn?.startedAt,
                completedAt: timestamp
            )
            state.status = "idle"
            state.settledAt = timestamp
        case "turn_aborted":
            let turnId = payload["turn_id"]?.stringValue ?? state.currentTurnId ?? state.sessionId
            // completedAt is what tells the phase resolver an interrupted turn is
            // over rather than still winding down.
            state.latestTurn = LatestTurn(
                turnId: turnId,
                state: "interrupted",
                startedAt: state.latestTurn?.startedAt,
                completedAt: timestamp
            )
            state.status = "idle"
            state.settledAt = timestamp
        case "token_count":
            guard let info = payload["info"] else { return }
            guard let used = info["total_token_usage"]?["total_tokens"]?.numberValue else { return }
            var fields: [String: JSONValue] = ["usedTokens": .number(used)]
            if let max = info["model_context_window"]?.numberValue {
                fields["maxTokens"] = .number(max)
            }
            replaceLast(
                kind: "context-window.updated",
                summary: "Context updated",
                payload: .object(fields),
                createdAt: timestamp
            )
        case "patch_apply_end":
            // Codex logs no start half for patches, so the finished row stands alone.
            var fields: [String: JSONValue] = ["itemType": .string("file_change")]
            let paths = Self.patchPaths(payload)
            if !paths.isEmpty {
                fields["data"] = .object([
                    "item": .object([
                        "changes": .array(paths.map { .object(["path": .string($0)]) }),
                    ]),
                ])
            }
            append(
                kind: "tool.completed",
                tone: "tool",
                summary: "Changed file",
                payload: .object(fields),
                turnId: state.currentTurnId,
                createdAt: timestamp
            )
        default:
            break
        }
    }

    private mutating func applyResponseItem(_ payload: JSONValue, timestamp: String) {
        let turnId = payload["internal_chat_message_metadata_passthrough"]?["turn_id"]?.stringValue
            ?? state.currentTurnId
        let type = payload["type"]?.stringValue

        switch type {
        case "function_call":
            switch payload["name"]?.stringValue {
            case "update_plan":
                applyUpdatePlan(payload, turnId: turnId, timestamp: timestamp)
            case "shell":
                // Older CLIs pass argv instead of the JS exec wrapper.
                let arguments = Self.decodeArguments(payload["arguments"])
                let argv = arguments?["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
                startCall(
                    payload,
                    summary: "Ran command",
                    itemType: "command_execution",
                    detail: argv.isEmpty ? nil : argv.joined(separator: " "),
                    turnId: turnId,
                    timestamp: timestamp
                )
            default:
                break
            }
        case "custom_tool_call":
            guard payload["name"]?.stringValue == "exec" else { return }
            let detail = payload["input"]?.stringValue.flatMap(Self.execCommand)
            startCall(
                payload,
                summary: "Ran command",
                itemType: "command_execution",
                detail: detail,
                turnId: turnId,
                timestamp: timestamp
            )
        case "message":
            guard payload["role"]?.stringValue == "user", state.title == nil else { return }
            state.title = Self.title(fromMessage: payload)
        case let type? where type.hasSuffix("_output"):
            completeCall(payload, turnId: turnId, timestamp: timestamp)
        default:
            break
        }
    }

    private mutating func applyUpdatePlan(
        _ payload: JSONValue,
        turnId: String?,
        timestamp: String
    ) {
        guard let entries = Self.decodeArguments(payload["arguments"])?["plan"]?.arrayValue else {
            return
        }
        var steps: [JSONValue] = []
        for entry in entries {
            guard let step = entry["step"]?.stringValue else { continue }
            let status = switch entry["status"]?.stringValue {
            case "in_progress": "inProgress"
            case "completed": "completed"
            default: "pending"
            }
            steps.append(.object(["step": .string(step), "status": .string(status)]))
        }
        guard !steps.isEmpty else { return }
        append(
            kind: "turn.plan.updated",
            tone: nil,
            summary: "Plan updated",
            payload: .object(["plan": .array(steps)]),
            turnId: turnId,
            createdAt: timestamp
        )
    }

    // MARK: - Tool call pairing

    private mutating func startCall(
        _ payload: JSONValue,
        summary: String,
        itemType: String,
        detail: String?,
        turnId: String?,
        timestamp: String
    ) {
        var fields: [String: JSONValue] = ["itemType": .string(itemType)]
        if let detail { fields["detail"] = .string(detail) }
        if let callId = payload["call_id"]?.stringValue {
            pendingCalls[callId] = PendingCall(summary: summary, itemType: itemType, detail: detail)
        }
        append(
            kind: "tool.started",
            tone: "tool",
            summary: summary,
            payload: .object(fields),
            turnId: turnId,
            createdAt: timestamp
        )
    }

    /// The completion half repeats the started half's detail verbatim, because
    /// `deriveRecentActivity` folds the pair by (kind, detail).
    private mutating func completeCall(_ payload: JSONValue, turnId: String?, timestamp: String) {
        guard let callId = payload["call_id"]?.stringValue,
              let call = pendingCalls.removeValue(forKey: callId)
        else { return }
        var fields: [String: JSONValue] = ["itemType": .string(call.itemType)]
        if let detail = call.detail { fields["detail"] = .string(detail) }
        append(
            kind: "tool.completed",
            tone: "tool",
            summary: call.summary,
            payload: .object(fields),
            turnId: turnId,
            createdAt: timestamp
        )
    }

    // MARK: - Activity plumbing

    private mutating func append(
        kind: String,
        tone: String?,
        summary: String,
        payload: JSONValue?,
        turnId: String?,
        createdAt: String
    ) {
        sequence += 1
        state.activities.append(
            ThreadActivity(
                id: "\(state.sessionId)-\(sequence)",
                tone: tone,
                kind: kind,
                summary: summary,
                payload: payload,
                turnId: turnId,
                sequence: sequence,
                createdAt: createdAt
            )
        )
        trim()
    }

    private mutating func replaceLast(
        kind: String,
        summary: String,
        payload: JSONValue,
        createdAt: String
    ) {
        if let index = state.activities.lastIndex(where: { $0.kind == kind }) {
            state.activities.remove(at: index)
        }
        append(
            kind: kind,
            tone: nil,
            summary: summary,
            payload: payload,
            turnId: state.currentTurnId,
            createdAt: createdAt
        )
    }

    private mutating func trim() {
        guard state.activities.count > Self.activityCap else { return }
        let keep = Set(
            [
                state.activities.last(where: { $0.kind == "turn.plan.updated" })?.id,
                state.activities.last(where: { $0.kind == "context-window.updated" })?.id,
            ].compactMap(\.self)
        )
        var overflow = state.activities.count - Self.activityCap
        state.activities.removeAll { activity in
            guard overflow > 0, !keep.contains(activity.id) else { return false }
            overflow -= 1
            return true
        }
    }

    // MARK: - Parsing helpers

    /// `arguments` is JSON encoded *as a string*, so it needs a second decode.
    private static func decodeArguments(_ value: JSONValue?) -> JSONValue? {
        guard let raw = value?.stringValue, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The exec tool's `input` is a JS snippet wrapping a JSON object, e.g.
    /// `const r = await tools.exec_command({"cmd":"rg -n \"foo\"", …});`. Missing
    /// the command only costs the row its detail.
    private static let commandExpression = try? NSRegularExpression(
        pattern: "\"?cmd\"?\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\""
    )

    static func execCommand(_ input: String) -> String? {
        guard let expression = commandExpression else { return nil }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = expression.firstMatch(in: input, range: range),
              let captured = Range(match.range(at: 1), in: input)
        else { return nil }
        return unescape(String(input[captured]))
    }

    /// Reuses JSON's own unescaping rules for the captured command.
    private static func unescape(_ escaped: String) -> String? {
        guard let data = "\"\(escaped)\"".data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    private static func patchPaths(_ payload: JSONValue) -> [String] {
        if let changes = payload["changes"]?.objectValue {
            return changes.keys.sorted()
        }
        if let changes = payload["changes"]?.arrayValue {
            return changes.compactMap { $0["path"]?.stringValue }
        }
        return []
    }

    private static func title(fromMessage payload: JSONValue) -> String? {
        let parts = payload["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
        let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Codex prepends tag-wrapped environment blocks to the first user turn.
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flattened.count > 60 ? String(flattened.prefix(60)) + "…" : flattened
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

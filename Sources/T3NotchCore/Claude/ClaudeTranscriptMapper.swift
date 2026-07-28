import Foundation

enum ClaudeTimestamp {
    static func now() -> String {
        iso8601(Date.now)
    }

    static func iso8601(fromMilliseconds millis: Double) -> String {
        iso8601(Date(timeIntervalSince1970: millis / 1000))
    }

    private static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
    }
}

/// Folds `~/.claude/projects/<slug>/<sessionId>.jsonl` records into the shape
/// the notch renders: activities, the open turn, branch, model, waiting flags.
///
/// Pure value type — the owning transport keeps one per session under its lock.
public struct ClaudeTranscriptMapper: Sendable, Equatable {
    private enum ToolUse: Sendable, Equatable {
        /// A row was emitted for the call; the result repeats it verbatim so the
        /// two halves fold into one row in `deriveRecentActivity`.
        case tool(summary: String, itemType: String?, detail: String?, turnId: String?)
        /// TaskCreate/TaskUpdate produce a plan, not a tool row.
        case task(input: [String: JSONValue])
        case question
    }

    private struct PlanTask: Sendable, Equatable {
        var subject: String
        var status: PlanStepStatus
    }

    public private(set) var activities: [ThreadActivity] = []
    public private(set) var latestTurn: LatestTurn?
    public private(set) var branch: String?
    public private(set) var model: String?
    /// AskUserQuestion cannot be answered from outside the terminal, so it only
    /// raises the waiting badge.
    public private(set) var pendingQuestionIds: Set<String> = []

    public var hasPendingUserInput: Bool { !pendingQuestionIds.isEmpty }

    private let root: String?
    private let activityCap: Int
    private var sequence = 0
    private var currentTurnId: String?
    private var toolUses: [String: ToolUse] = [:]
    private var tasks: [String: PlanTask] = [:]
    private var taskOrder: [String] = []

    public init(root: String? = nil, activityCap: Int = 300) {
        self.root = root
        self.activityCap = activityCap
    }

    // MARK: - Ingest

    @discardableResult
    public mutating func ingest(line: Data) -> Bool {
        guard let record = try? JSONDecoder().decode(JSONValue.self, from: line) else { return false }
        return ingest(record: record)
    }

    @discardableResult
    public mutating func ingest(record: JSONValue) -> Bool {
        guard let object = record.objectValue else { return false }
        // Subagent transcripts interleave into the same file; their tool calls
        // are not this thread's work.
        guard object["isSidechain"]?.boolValue != true else { return false }

        var changed = false
        if let value = object["gitBranch"]?.stringValue, !value.isEmpty, value != branch {
            branch = value
            changed = true
        }

        let timestamp = object["timestamp"]?.stringValue ?? ClaudeTimestamp.now()
        switch object["type"]?.stringValue {
        case "assistant":
            changed = ingestAssistant(object, at: timestamp) || changed
        case "user":
            changed = ingestUser(object, at: timestamp) || changed
        case "system":
            if object["subtype"]?.stringValue == "turn_duration" {
                changed = closeTurn(at: timestamp) || changed
            }
        default:
            break
        }
        return changed
    }

    /// Appends a row the transcript does not carry (approvals come from hooks).
    public mutating func appendExternalActivity(
        id: String,
        kind: String,
        tone: String?,
        summary: String,
        payload: JSONValue?,
        createdAt: String
    ) {
        appendActivity(
            id: id,
            kind: kind,
            tone: tone,
            summary: summary,
            payload: payload,
            turnId: currentTurnId,
            createdAt: createdAt
        )
    }

    // MARK: - Record kinds

    private mutating func ingestAssistant(_ object: [String: JSONValue], at timestamp: String) -> Bool {
        var changed = false
        guard let message = object["message"]?.objectValue else { return false }

        if let value = message["model"]?.stringValue, !value.isEmpty, value != model {
            model = value
            changed = true
        }
        if let usage = message["usage"]?.objectValue {
            changed = applyUsage(usage, at: timestamp) || changed
        }

        for item in message["content"]?.arrayValue ?? [] {
            guard let block = item.objectValue,
                  block["type"]?.stringValue == "tool_use",
                  let id = block["id"]?.stringValue,
                  let name = block["name"]?.stringValue
            else { continue }
            changed = startToolUse(
                id: id,
                name: name,
                input: block["input"]?.objectValue ?? [:],
                at: timestamp
            ) || changed
        }
        return changed
    }

    private mutating func ingestUser(_ object: [String: JSONValue], at timestamp: String) -> Bool {
        let content = object["message"]?["content"]?.arrayValue ?? []
        let results = content.compactMap { item -> String? in
            guard let block = item.objectValue,
                  block["type"]?.stringValue == "tool_result"
            else { return nil }
            return block["tool_use_id"]?.stringValue
        }

        if !results.isEmpty {
            var changed = false
            for id in results {
                changed = finishToolUse(id: id, record: object, at: timestamp) || changed
            }
            return changed
        }

        // Anything else typed by the user opens a turn — except the synthetic
        // records Claude injects (command output, hook feedback).
        guard object["isMeta"]?.boolValue != true else { return false }
        return openTurn(id: object["uuid"]?.stringValue, at: timestamp)
    }

    private mutating func applyUsage(_ usage: [String: JSONValue], at timestamp: String) -> Bool {
        let used = (usage["input_tokens"]?.numberValue ?? 0)
            + (usage["cache_read_input_tokens"]?.numberValue ?? 0)
            + (usage["cache_creation_input_tokens"]?.numberValue ?? 0)
        guard used > 0 else { return false }
        let maxTokens: Double = (model?.contains("[1m]") == true) ? 1_000_000 : 200_000

        // One context row per session: the newest reading replaces the last.
        if let index = activities.lastIndex(where: { $0.kind == "context-window.updated" }) {
            activities.remove(at: index)
        }
        appendActivity(
            id: "context-\(sequence + 1)",
            kind: "context-window.updated",
            tone: nil,
            summary: "Context updated",
            payload: .object(["usedTokens": .number(used), "maxTokens": .number(maxTokens)]),
            turnId: currentTurnId,
            createdAt: timestamp
        )
        return true
    }

    // MARK: - Turns

    private mutating func openTurn(id: String?, at timestamp: String) -> Bool {
        guard let id else { return false }
        currentTurnId = id
        let turn = LatestTurn(turnId: id, state: "running", startedAt: timestamp)
        guard latestTurn != turn else { return false }
        latestTurn = turn
        return true
    }

    private mutating func closeTurn(at timestamp: String) -> Bool {
        guard var turn = latestTurn, turn.state == "running" else { return false }
        turn.state = "completed"
        turn.completedAt = timestamp
        latestTurn = turn
        return true
    }

    // MARK: - Tools

    private mutating func startToolUse(
        id: String,
        name: String,
        input: [String: JSONValue],
        at timestamp: String
    ) -> Bool {
        switch name {
        case "TaskCreate", "TaskUpdate":
            toolUses[id] = .task(input: input)
            return false
        case "AskUserQuestion":
            toolUses[id] = .question
            pendingQuestionIds.insert(id)
            return true
        default:
            break
        }

        let (summary, itemType, detail) = describe(tool: name, input: input)
        toolUses[id] = .tool(
            summary: summary,
            itemType: itemType,
            detail: detail,
            turnId: currentTurnId
        )
        appendActivity(
            id: "start-\(id)",
            kind: "tool.started",
            tone: "tool",
            summary: summary,
            payload: toolPayload(itemType: itemType, detail: detail),
            turnId: currentTurnId,
            createdAt: timestamp
        )
        return true
    }

    private mutating func finishToolUse(
        id: String,
        record: [String: JSONValue],
        at timestamp: String
    ) -> Bool {
        guard let use = toolUses.removeValue(forKey: id) else { return false }
        switch use {
        case .question:
            pendingQuestionIds.remove(id)
            return true
        case let .task(input):
            return applyTaskResult(input: input, record: record, at: timestamp)
        case let .tool(summary, itemType, detail, turnId):
            appendActivity(
                id: "done-\(id)",
                kind: "tool.completed",
                tone: "tool",
                summary: summary,
                payload: toolPayload(itemType: itemType, detail: detail),
                turnId: turnId,
                createdAt: timestamp
            )
            return true
        }
    }

    /// Summary/itemType/detail are emitted identically on both halves so
    /// `deriveRecentActivity` folds them into a single row.
    private func describe(
        tool name: String,
        input: [String: JSONValue]
    ) -> (summary: String, itemType: String?, detail: String?) {
        switch name {
        case "Bash":
            return ("Ran command", "command_execution", input["command"]?.stringValue)
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return ("Changed file", "file_change", path(input["file_path"]))
        case "Read":
            return ("Read file", "file_change", path(input["file_path"]))
        case "WebSearch", "WebFetch":
            return (
                "Searched web",
                "web_search",
                input["query"]?.stringValue ?? input["url"]?.stringValue
            )
        case "Grep", "Glob":
            // No itemType: the label fallback in `toolActivityKind` classifies it.
            return ("Searched files", nil, input["pattern"]?.stringValue)
        case "Task", "Agent":
            return ("Ran subagent", "dynamic_tool_call", input["description"]?.stringValue)
        default:
            if name.hasPrefix("mcp__") {
                return ("Ran tool", "mcp_tool_call", prettifiedMCPName(name))
            }
            return ("Ran tool", "dynamic_tool_call", name)
        }
    }

    private func toolPayload(itemType: String?, detail: String?) -> JSONValue? {
        var payload: [String: JSONValue] = [:]
        if let itemType { payload["itemType"] = .string(itemType) }
        if let detail, !detail.isEmpty { payload["detail"] = .string(detail) }
        return payload.isEmpty ? nil : .object(payload)
    }

    private func path(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue, !raw.isEmpty else { return nil }
        return shortenedPath(raw, relativeTo: root)
    }

    private func prettifiedMCPName(_ name: String) -> String {
        let parts = name.dropFirst("mcp__".count)
            .components(separatedBy: "__")
            .filter { !$0.isEmpty }
        return parts.isEmpty ? name : parts.joined(separator: "/")
    }

    // MARK: - Plan

    private mutating func applyTaskResult(
        input: [String: JSONValue],
        record: [String: JSONValue],
        at timestamp: String
    ) -> Bool {
        let result = record["toolUseResult"]
        var changed = false

        if let list = result?["tasks"]?.arrayValue {
            // A full list replaces the map, so removed tasks disappear.
            tasks.removeAll()
            taskOrder.removeAll()
            for entry in list {
                changed = upsertTask(entry.objectValue, fallback: [:]) || changed
            }
        } else if let task = result?["task"]?.objectValue {
            changed = upsertTask(task, fallback: input)
        } else {
            changed = upsertTask(input, fallback: [:])
        }
        guard changed, !taskOrder.isEmpty else { return false }

        let plan = taskOrder.compactMap { id -> JSONValue? in
            guard let task = tasks[id] else { return nil }
            return .object(["step": .string(task.subject), "status": .string(task.status.rawValue)])
        }
        appendActivity(
            id: "plan-\(record["uuid"]?.stringValue ?? String(sequence + 1))",
            kind: "turn.plan.updated",
            tone: nil,
            summary: "Plan updated",
            payload: .object(["plan": .array(plan)]),
            turnId: currentTurnId,
            createdAt: timestamp
        )
        return true
    }

    private mutating func upsertTask(
        _ object: [String: JSONValue]?,
        fallback: [String: JSONValue]
    ) -> Bool {
        guard let object else { return false }
        let id = object["task_id"]?.stringValue
            ?? object["id"]?.stringValue
            ?? fallback["task_id"]?.stringValue
            ?? fallback["id"]?.stringValue
        guard let id else { return false }
        let subject = object["subject"]?.stringValue
            ?? fallback["subject"]?.stringValue
            ?? tasks[id]?.subject
        guard let subject, !subject.isEmpty else { return false }
        let status = planStepStatus(
            object["status"]?.stringValue ?? fallback["status"]?.stringValue
        )

        if tasks[id] == nil { taskOrder.append(id) }
        tasks[id] = PlanTask(subject: subject, status: status)
        return true
    }

    private func planStepStatus(_ raw: String?) -> PlanStepStatus {
        switch raw {
        case "in_progress", "inProgress", "active": return .inProgress
        case "completed", "done": return .completed
        default: return .pending
        }
    }

    // MARK: - Activity storage

    private mutating func appendActivity(
        id: String,
        kind: String,
        tone: String?,
        summary: String,
        payload: JSONValue?,
        turnId: String?,
        createdAt: String
    ) {
        sequence += 1
        activities.append(
            ThreadActivity(
                id: id,
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

    /// Drops the oldest tool rows once the cap is passed. Approvals, waiting
    /// prompts, the current plan and the current context reading are what the
    /// notch renders as state, so they are never candidates.
    private mutating func trim() {
        guard activities.count > activityCap else { return }
        var protectedIndices = Set<Int>()
        for (index, activity) in activities.enumerated()
        where activity.kind.hasPrefix("approval.") || activity.kind.hasPrefix("user-input.") {
            protectedIndices.insert(index)
        }
        if let index = activities.lastIndex(where: { $0.kind == "turn.plan.updated" }) {
            protectedIndices.insert(index)
        }
        if let index = activities.lastIndex(where: { $0.kind == "context-window.updated" }) {
            protectedIndices.insert(index)
        }

        var remaining = activities.count - activityCap
        var kept: [ThreadActivity] = []
        kept.reserveCapacity(activityCap)
        for (index, activity) in activities.enumerated() {
            if remaining > 0, !protectedIndices.contains(index) {
                remaining -= 1
                continue
            }
            kept.append(activity)
        }
        activities = kept
    }
}

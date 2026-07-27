import Foundation

// MARK: - Awareness phase

public enum AgentAwarenessPhase: String, Sendable, Equatable, CaseIterable {
    case starting
    case running
    case waitingForApproval = "waiting_for_approval"
    case waitingForInput = "waiting_for_input"
    case completed
    case failed
    case stale
}

/// Port of `resolveThreadAwarenessPhase` from packages/shared/src/agentAwareness.ts
public func resolveThreadAwarenessPhase(_ thread: ThreadShell) -> AgentAwarenessPhase? {
    if thread.hasPendingApprovals {
        return .waitingForApproval
    }
    if thread.hasPendingUserInput {
        return .waitingForInput
    }
    if thread.session?.status == "error" || thread.latestTurn?.state == "error" {
        return .failed
    }
    if thread.session?.status == "starting" {
        return .starting
    }
    if thread.session?.status == "running" || thread.latestTurn?.state == "running" {
        return .running
    }
    if thread.latestTurn?.state == "completed" {
        return .completed
    }
    // A turn that finished can still read as "interrupted" here: session
    // teardown settles still-running turns by session status, and that write
    // can race the turn.completed one. completedAt survives the race.
    if thread.latestTurn?.state == "interrupted", thread.latestTurn?.completedAt != nil {
        return .completed
    }
    if thread.session?.status == "ready" || thread.session?.status == "idle" {
        return .completed
    }
    return nil
}

public func headline(for phase: AgentAwarenessPhase) -> String {
    switch phase {
    case .starting: return "Starting"
    case .running: return "Working"
    case .waitingForApproval: return "Needs approval"
    case .waitingForInput: return "Needs input"
    case .completed: return "Done"
    case .failed: return "Failed"
    case .stale: return "Stale"
    }
}

// MARK: - Pending approvals / user input

public struct PendingApproval: Sendable, Equatable, Identifiable {
    public var id: String { requestId }
    public var requestId: String
    public var requestKind: String
    public var createdAt: String
    public var detail: String?

    public init(requestId: String, requestKind: String, createdAt: String, detail: String? = nil) {
        self.requestId = requestId
        self.requestKind = requestKind
        self.createdAt = createdAt
        self.detail = detail
    }
}

public struct UserInputOption: Sendable, Equatable, Identifiable {
    public var id: String { label }
    public var label: String
    public var description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

public struct UserInputQuestion: Sendable, Equatable, Identifiable {
    public var id: String
    public var header: String
    public var question: String
    public var options: [UserInputOption]
    public var multiSelect: Bool

    public init(
        id: String,
        header: String,
        question: String,
        options: [UserInputOption],
        multiSelect: Bool = false
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }
}

public struct PendingUserInput: Sendable, Equatable, Identifiable {
    public var id: String { requestId }
    public var requestId: String
    public var createdAt: String
    public var questions: [UserInputQuestion]

    public init(requestId: String, createdAt: String, questions: [UserInputQuestion]) {
        self.requestId = requestId
        self.createdAt = createdAt
        self.questions = questions
    }
}

public func derivePendingApprovals(from activities: [ThreadActivity]) -> [PendingApproval] {
    var openByRequestId: [String: PendingApproval] = [:]
    for activity in orderedActivities(activities) {
        let payload = activity.payload?.objectValue
        guard let requestId = payload?["requestId"]?.stringValue else { continue }
        let detail = payload?["detail"]?.stringValue
        let requestKind =
            payload?["requestKind"]?.stringValue.flatMap(normalizedRequestKind)
            ?? requestKind(fromRequestType: payload?["requestType"])

        if activity.kind == "approval.requested", let requestKind {
            openByRequestId[requestId] = PendingApproval(
                requestId: requestId,
                requestKind: requestKind,
                createdAt: activity.createdAt,
                detail: detail
            )
            continue
        }

        if activity.kind == "approval.resolved" {
            openByRequestId.removeValue(forKey: requestId)
            continue
        }

        if activity.kind == "provider.approval.respond.failed",
           isStalePendingRequestFailureDetail(detail)
        {
            openByRequestId.removeValue(forKey: requestId)
        }
    }

    return openByRequestId.values.sorted { $0.createdAt < $1.createdAt }
}

public func derivePendingUserInputs(from activities: [ThreadActivity]) -> [PendingUserInput] {
    var openByRequestId: [String: PendingUserInput] = [:]
    for activity in orderedActivities(activities) {
        let payload = activity.payload?.objectValue
        guard let requestId = payload?["requestId"]?.stringValue else { continue }
        let detail = payload?["detail"]?.stringValue

        if activity.kind == "user-input.requested" {
            guard let questions = parseUserInputQuestions(payload) else { continue }
            openByRequestId[requestId] = PendingUserInput(
                requestId: requestId,
                createdAt: activity.createdAt,
                questions: questions
            )
            continue
        }

        if activity.kind == "user-input.resolved" {
            openByRequestId.removeValue(forKey: requestId)
            continue
        }

        if activity.kind == "provider.user-input.respond.failed",
           isStalePendingRequestFailureDetail(detail)
        {
            openByRequestId.removeValue(forKey: requestId)
        }
    }

    return openByRequestId.values.sorted { $0.createdAt < $1.createdAt }
}

// MARK: - Plan / context

public enum PlanStepStatus: String, Sendable, Equatable {
    case pending
    case inProgress
    case completed
}

public struct PlanStep: Sendable, Equatable, Identifiable {
    public var id: String { step }
    public var step: String
    public var status: PlanStepStatus

    public init(step: String, status: PlanStepStatus) {
        self.step = step
        self.status = status
    }
}

public struct ActivePlanState: Sendable, Equatable {
    public var explanation: String?
    public var steps: [PlanStep]
    public var updatedAt: String

    public init(explanation: String? = nil, steps: [PlanStep], updatedAt: String) {
        self.explanation = explanation
        self.steps = steps
        self.updatedAt = updatedAt
    }
}

public func deriveActivePlanState(
    from activities: [ThreadActivity],
    latestTurnId: String?
) -> ActivePlanState? {
    let ordered = orderedActivities(activities)
    let planActivities = ordered.filter { $0.kind == "turn.plan.updated" }
    let latest: ThreadActivity?
    if let latestTurnId,
       let fromTurn = planActivities.last(where: { $0.turnId == latestTurnId })
    {
        latest = fromTurn
    } else {
        latest = planActivities.last
    }
    guard let latest else { return nil }
    guard let planArray = latest.payload?["plan"]?.arrayValue else { return nil }

    var steps: [PlanStep] = []
    for entry in planArray {
        guard let object = entry.objectValue,
              let step = object["step"]?.stringValue,
              let statusRaw = object["status"]?.stringValue,
              let status = PlanStepStatus(rawValue: statusRaw)
        else { continue }
        steps.append(PlanStep(step: step, status: status))
    }
    guard !steps.isEmpty else { return nil }
    return ActivePlanState(
        explanation: latest.payload?["explanation"]?.stringValue,
        steps: steps,
        updatedAt: latest.createdAt
    )
}

public struct ContextWindowSnapshot: Sendable, Equatable {
    public var usedTokens: Double
    public var maxTokens: Double?
    public var usedPercentage: Double?
    public var toolUses: Double?
    public var durationMs: Double?
    public var updatedAt: String

    public init(
        usedTokens: Double,
        maxTokens: Double? = nil,
        usedPercentage: Double? = nil,
        toolUses: Double? = nil,
        durationMs: Double? = nil,
        updatedAt: String
    ) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
        self.usedPercentage = usedPercentage
        self.toolUses = toolUses
        self.durationMs = durationMs
        self.updatedAt = updatedAt
    }
}

public func deriveLatestContextWindowSnapshot(
    from activities: [ThreadActivity]
) -> ContextWindowSnapshot? {
    for activity in activities.reversed() {
        guard activity.kind == "context-window.updated" else { continue }
        guard let usedTokens = activity.payload?["usedTokens"]?.numberValue, usedTokens >= 0 else {
            continue
        }
        let maxTokens = activity.payload?["maxTokens"]?.numberValue
        let usedPercentage: Double?
        if let maxTokens, maxTokens > 0 {
            usedPercentage = min(100, (usedTokens / maxTokens) * 100)
        } else {
            usedPercentage = nil
        }
        return ContextWindowSnapshot(
            usedTokens: usedTokens,
            maxTokens: maxTokens,
            usedPercentage: usedPercentage,
            toolUses: activity.payload?["toolUses"]?.numberValue,
            durationMs: activity.payload?["durationMs"]?.numberValue,
            updatedAt: activity.createdAt
        )
    }
    return nil
}

// MARK: - Recent activity

public enum ActivityEventKind: Sendable, Equatable {
    case command
    case fileChange
    case search
    case tool
    case image
    case other
}

/// One thing the agent did: a command it ran, a file it changed, a search it made.
public struct ActivityEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: ActivityEventKind
    /// The server's own wording, minus the lifecycle suffix — "Ran command".
    public var label: String
    /// What it acted on: the command line, or the path(s) touched.
    public var detail: String?
    public var isRunning: Bool
    public var createdAt: String

    public init(
        id: String,
        kind: ActivityEventKind,
        label: String,
        detail: String? = nil,
        isRunning: Bool,
        createdAt: String
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.detail = detail
        self.isRunning = isRunning
        self.createdAt = createdAt
    }
}

/// The newest `limit` tool actions, one row per action, oldest first.
///
/// `tool.started` and `tool.completed` are separate activities that share no
/// correlation id, so they are folded back together here — otherwise every
/// command would be listed twice, once running and once done. Paths are made
/// relative to `root` (the worktree) to fit a notch-width row.
public func deriveRecentActivity(
    from activities: [ThreadActivity],
    limit: Int = 5,
    relativeTo root: String? = nil
) -> [ActivityEvent] {
    guard limit > 0 else { return [] }
    var rows: [ActivityEvent] = []

    for activity in orderedActivities(activities) {
        guard activity.tone == "tool" || activity.kind.hasPrefix("tool.") else { continue }
        // `tool.updated` carries process plumbing under a bare "Tool updated"
        // summary; whichever row it belongs to is already listed.
        guard activity.kind != "tool.updated" else { continue }

        let payload = activity.payload?.objectValue
        let label = toolActivityLabel(activity.summary)
        guard !label.isEmpty else { continue }
        let kind = toolActivityKind(itemType: payload?["itemType"]?.stringValue, label: label)
        let detail = toolActivityDetail(payload, relativeTo: root)
        let isCompletion = activity.kind == "tool.completed"

        if isCompletion, let index = openRowIndex(in: rows, kind: kind, detail: detail) {
            rows[index].label = label
            // Only a completion knows which files a change touched.
            rows[index].detail = detail ?? rows[index].detail
            rows[index].isRunning = false
            rows[index].createdAt = activity.createdAt
            // Finishing is the newest thing that happened, so the row moves last.
            rows.append(rows.remove(at: index))
            continue
        }

        rows.append(
            ActivityEvent(
                id: activity.id,
                kind: kind,
                label: label,
                detail: detail,
                isRunning: !isCompletion,
                createdAt: activity.createdAt
            )
        )
    }

    return Array(rows.suffix(limit))
}

/// The running row a completion closes. Commands match on their command line,
/// since several can be in flight; the other item types send no detail while
/// running, so their type is all there is to match on.
private func openRowIndex(
    in rows: [ActivityEvent],
    kind: ActivityEventKind,
    detail: String?
) -> Int? {
    rows.lastIndex { row in
        guard row.isRunning, row.kind == kind else { return false }
        guard let rowDetail = row.detail, let detail else { return true }
        return rowDetail == detail
    }
}

/// "Ran command started" -> "Ran command"; the row's own spinner says it's running.
func toolActivityLabel(_ summary: String) -> String {
    var value = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    for suffix in [" started", " completed", " complete"]
    where value.lowercased().hasSuffix(suffix) {
        value = String(value.dropLast(suffix.count))
        break
    }
    return value.trimmingCharacters(in: .whitespaces)
}

func toolActivityKind(itemType: String?, label: String) -> ActivityEventKind {
    switch itemType {
    case "command_execution": return .command
    case "file_change": return .fileChange
    case "web_search": return .search
    case "mcp_tool_call", "dynamic_tool_call", "collab_agent_tool_call": return .tool
    case "image_view": return .image
    default: break
    }
    // Older activities predate `itemType`, so fall back on the wording.
    let lowered = label.lowercased()
    if lowered.hasPrefix("ran command") || lowered.hasPrefix("terminal") { return .command }
    if lowered.hasPrefix("file change") || lowered.hasPrefix("changed file") { return .fileChange }
    if lowered.hasPrefix("read file") { return .fileChange }
    if lowered.contains("search") { return .search }
    return .other
}

/// What the action acted on: its command line, or the file(s) it touched.
func toolActivityDetail(_ payload: [String: JSONValue]?, relativeTo root: String?) -> String? {
    if let raw = payload?["detail"]?.stringValue, let detail = readableCommandDetail(raw) {
        return detail
    }
    // File changes name their paths in the completion data, never in `detail`.
    let changes = payload?["data"]?["item"]?["changes"]?.arrayValue ?? []
    let paths = changes.compactMap { $0["path"]?.stringValue }
    guard let first = paths.first else { return nil }
    let shortened = shortenedPath(first, relativeTo: root)
    return paths.count > 1 ? "\(shortened) +\(paths.count - 1)" : shortened
}

/// Strips the shell wrapper agents run everything through, so a row reads
/// `git status --short` instead of `/bin/zsh -lc "git status --short"`.
func readableCommandDetail(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    // Scripts and heredocs arrive with newlines; a row is one line.
    return unwrappedShellCommand(value)
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .nilIfEmpty
}

func unwrappedShellCommand(_ value: String) -> String {
    let parts = value.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count == 3 else { return value }
    let shell = parts[0].split(separator: "/").last.map(String.init) ?? parts[0]
    guard ["sh", "bash", "zsh", "dash", "fish", "ksh"].contains(shell) else { return value }
    // -c, -lc, -lic, ...
    let flags = parts[1].dropFirst()
    guard parts[1].hasPrefix("-"), flags.contains("c"), flags.allSatisfy({ "clie".contains($0) })
    else { return value }

    var body = parts[2].trimmingCharacters(in: .whitespaces)
    // The closing quote is often missing: the server truncates long details, so
    // the opening quote is dropped on its own rather than left dangling.
    for quote in ["\"", "'"] where body.hasPrefix(quote) {
        body = String(body.dropFirst())
        if body.hasSuffix(quote) {
            body = String(body.dropLast())
        }
        if quote == "\"" {
            body = body.replacingOccurrences(of: "\\\"", with: "\"")
        }
        break
    }
    return body
}

/// Trims a path to something that fits a notch row: relative to the worktree
/// when it lives there, otherwise its last few components.
func shortenedPath(_ path: String, relativeTo root: String?) -> String {
    if let root, !root.isEmpty {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
    }
    let components = path.split(separator: "/")
    guard components.count > 3 else { return path }
    return components.suffix(3).joined(separator: "/")
}

// MARK: - Helpers

func orderedActivities(_ activities: [ThreadActivity]) -> [ThreadActivity] {
    activities.sorted { lhs, rhs in
        if let ls = lhs.sequence, let rs = rhs.sequence, ls != rs {
            return ls < rs
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        // Fast tools open and close inside the same millisecond, and with no
        // sequence number id order is arbitrary — so fall back to lifecycle
        // order, or a finished command reads as still running and a resolved
        // approval reads as still pending.
        if lifecycleRank(lhs.kind) != lifecycleRank(rhs.kind) {
            return lifecycleRank(lhs.kind) < lifecycleRank(rhs.kind)
        }
        return lhs.id < rhs.id
    }
}

/// Where a kind falls in an open -> update -> close lifecycle.
private func lifecycleRank(_ kind: String) -> Int {
    if kind.hasSuffix(".started") || kind.hasSuffix(".requested") { return 0 }
    if kind.hasSuffix(".completed") || kind.hasSuffix(".resolved") || kind.hasSuffix(".failed") {
        return 2
    }
    return 1
}

func normalizedRequestKind(_ value: String) -> String? {
    switch value {
    case "command", "file-read", "file-change":
        return value
    default:
        return nil
    }
}

func requestKind(fromRequestType requestType: JSONValue?) -> String? {
    guard let raw = requestType?.stringValue else { return nil }
    switch raw {
    case "command_execution_approval", "exec_command_approval":
        return "command"
    case "file_read_approval":
        return "file-read"
    case "file_change_approval", "apply_patch_approval":
        return "file-change"
    default:
        return nil
    }
}

func isStalePendingRequestFailureDetail(_ detail: String?) -> Bool {
    guard let detail else { return false }
    let lowered = detail.lowercased()
    return lowered.contains("not found")
        || lowered.contains("already resolved")
        || lowered.contains("no longer pending")
        || lowered.contains("unknown request")
}

func parseUserInputQuestions(_ payload: [String: JSONValue]?) -> [UserInputQuestion]? {
    guard let questions = payload?["questions"]?.arrayValue else { return nil }
    var parsed: [UserInputQuestion] = []
    for entry in questions {
        guard let question = entry.objectValue,
              let id = question["id"]?.stringValue,
              let header = question["header"]?.stringValue,
              let text = question["question"]?.stringValue,
              let optionsRaw = question["options"]?.arrayValue
        else { continue }

        var options: [UserInputOption] = []
        for optionEntry in optionsRaw {
            guard let option = optionEntry.objectValue,
                  let label = option["label"]?.stringValue,
                  let description = option["description"]?.stringValue
            else { continue }
            options.append(UserInputOption(label: label, description: description))
        }
        guard !options.isEmpty else { continue }
        parsed.append(
            UserInputQuestion(
                id: id,
                header: header,
                question: text,
                options: options,
                multiSelect: question["multiSelect"]?.boolValue == true
            )
        )
    }
    return parsed.isEmpty ? nil : parsed
}

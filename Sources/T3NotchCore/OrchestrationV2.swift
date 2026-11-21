import Foundation

struct OrchestrationV2Shell: Decodable {
    let snapshotSequence: Int
    let projects: [ProjectShell]
    let threads: [Thread]

    var snapshot: ShellSnapshot {
        ShellSnapshot(
            snapshotSequence: snapshotSequence,
            projects: projects,
            threads: threads.map(\.shell),
            updatedAt: threads.map(\.updatedAt).max() ?? ""
        )
    }

    struct Thread: Decodable {
        let id: String
        let projectId: String
        let title: String
        let modelSelection: ModelSelection
        let runtimeMode: String?
        let interactionMode: String?
        let branch: String?
        let worktreePath: String?
        let createdAt: String?
        let updatedAt: String
        let archivedAt: String?
        let settledAt: String?
        let latestUserMessageAt: String?
        let hasActionableProposedPlan: Bool?
        let activeRunId: String?
        let latestRunId: String?
        let latestRunRequestedAt: String?
        let latestRunStartedAt: String?
        let latestRunCompletedAt: String?
        let activityRunStatus: String?
        let activityRunStartedAt: String?
        let status: String
        let pendingRuntimeRequest: Request?

        var shell: ThreadShell {
            let phase = OrchestrationV2Shell.phase(activityRunStatus ?? status)
            let turn = (activeRunId ?? latestRunId).map {
                LatestTurn(
                    turnId: $0, state: phase,
                    requestedAt: latestRunRequestedAt,
                    startedAt: activityRunStartedAt ?? latestRunStartedAt,
                    completedAt: latestRunCompletedAt
                )
            }
            return ThreadShell(
                id: id, projectId: projectId, title: title, modelSelection: modelSelection,
                runtimeMode: runtimeMode, interactionMode: interactionMode,
                branch: branch, worktreePath: worktreePath, latestTurn: turn,
                createdAt: createdAt, updatedAt: updatedAt, archivedAt: archivedAt,
                settledAt: settledAt, session: turn.map { Session(status: $0.state) },
                latestUserMessageAt: latestUserMessageAt,
                hasPendingApprovals: pendingRuntimeRequest?.isApproval ?? false,
                hasPendingUserInput: pendingRuntimeRequest?.isInput ?? false,
                hasActionableProposedPlan: hasActionableProposedPlan
            )
        }
    }

    struct Request: Decodable {
        let id: String
        let kind: String
        let status: String?
        let createdAt: String

        var isInput: Bool { kind == "user_input" || kind == "auth_refresh" }

        var isApproval: Bool {
            ["command", "file-read", "file-change", "permission", "mcp-elicitation"].contains(kind)
        }
    }

    static func phase(_ status: String) -> String {
        switch status {
        case "preparing", "queued": return "starting"
        case "waiting": return "running"
        case "failed": return "error"
        case "cancelled", "rolled_back": return "interrupted"
        default: return status
        }
    }
}

struct OrchestrationV2Detail: Decodable {
    let snapshotSequence: Int
    let projection: Projection

    struct Projection: Decodable {
        // The common thread metadata already matches the legacy model.
        let thread: ThreadMetadata
        let runs: [Run]
        let runtimeRequests: [OrchestrationV2Shell.Request]
        let messages: [ThreadMessage]
        let turnItems: [[String: JSONValue]]

        struct ThreadMetadata: Decodable {
            let id: String
            let projectId: String
            let title: String
            let modelSelection: ModelSelection
            let runtimeMode: String?
            let interactionMode: String?
            let branch: String?
            let worktreePath: String?
            let createdAt: String?
            let updatedAt: String
        }

        struct Run: Decodable {
            let id: String
            let ordinal: Int
            let status: String
            let requestedAt: String?
            let startedAt: String?
            let completedAt: String?
        }

        var detail: ThreadDetail {
            let run = runs.max { $0.ordinal < $1.ordinal }
            let turn = run.map {
                LatestTurn(
                    turnId: $0.id, state: OrchestrationV2Shell.phase($0.status),
                    requestedAt: $0.requestedAt, startedAt: $0.startedAt, completedAt: $0.completedAt
                )
            }
            let requests = runtimeRequests.filter { $0.status == "pending" }
            let itemsByRequest = Dictionary(
                turnItems.compactMap { item in item["requestId"]?.stringValue.map { ($0, item) } },
                uniquingKeysWith: { first, last in
                    first["type"]?.stringValue == "approval_request"
                    || first["type"]?.stringValue == "user_input_request" ? first : last
                }
            )
            let activities = turnItems.compactMap(Self.activity) + requests.compactMap { request in
                let item = itemsByRequest[request.id]
                var payload: [String: JSONValue] = ["requestId": .string(request.id)]
                let kind: String
                if request.kind == "user_input" {
                    kind = "user-input.requested"
                    payload["questions"] = item?["questions"]
                } else if request.isApproval {
                    kind = "approval.requested"
                    payload["requestKind"] = .string(request.kind)
                    payload["detail"] = item?["prompt"] ?? item?["reason"] ?? item?["title"]
                } else {
                    return nil
                }
                return ThreadActivity(
                    id: request.id, kind: kind, summary: kind,
                    payload: .object(payload), createdAt: request.createdAt
                )
            }
            return ThreadDetail(
                id: thread.id, projectId: thread.projectId, title: thread.title,
                modelSelection: thread.modelSelection, runtimeMode: thread.runtimeMode,
                interactionMode: thread.interactionMode, branch: thread.branch,
                worktreePath: thread.worktreePath, latestTurn: turn, createdAt: thread.createdAt,
                updatedAt: thread.updatedAt, messages: messages, activities: activities
            )
        }

        private static func activity(from item: [String: JSONValue]) -> ThreadActivity? {
            guard let id = item["id"]?.stringValue, let type = item["type"]?.stringValue,
                  let date = item["updatedAt"]?.stringValue
            else { return nil }

            var payload = ["itemType": JSONValue.string(type)]
            let kind: String
            let summary: String
            switch type {
            case "todo_list":
                kind = "turn.plan.updated"
                summary = "Updated plan"
                payload["explanation"] = item["explanation"]
                payload["plan"] = .array((item["steps"]?.arrayValue ?? []).compactMap { step in
                    guard let text = step["text"], let status = step["status"]?.stringValue else { return nil }
                    return .object(["step": text, "status": .string(status == "running" ? "inProgress" : status)])
                })
            case "command_execution", "file_change", "file_search", "web_search",
                 "mcp_tool_call", "dynamic_tool_call", "image_view":
                let running = ["pending", "running", "streaming"].contains(item["status"]?.stringValue ?? "")
                kind = running ? "tool.started" : "tool.completed"
                let labels = [
                    "command_execution": "Ran command", "file_change": "Changed file",
                    "file_search": "Searched files", "web_search": "Searched the web",
                    "mcp_tool_call": "Called tool", "dynamic_tool_call": "Called tool",
                    "image_view": "Viewed image",
                ]
                summary = labels[type] ?? type
                payload["detail"] = item["input"] ?? item["fileName"] ?? item["pattern"] ?? item["title"]
            default:
                return nil
            }
            return ThreadActivity(
                id: id, kind: kind, summary: summary, payload: .object(payload),
                turnId: item["runId"]?.stringValue, createdAt: date
            )
        }
    }
}

struct OrchestrationV2CommandFrame: Encodable {
    let _tag = "Request"
    let id = 1
    let tag = "orchestration.dispatchCommand"
    let headers: [[String]] = []
    let payload: [String: JSONValue]

    init(command: DispatchCommand) throws {
        switch command {
        case let .approvalRespond(commandId, threadId, requestId, decision, _):
            payload = [
                "type": .string("runtime-request.respond"), "commandId": .string(commandId),
                "threadId": .string(threadId), "requestId": .string(requestId),
                "decision": .string(decision.rawValue),
            ]
        case let .userInputRespond(commandId, threadId, requestId, answers, _):
            payload = [
                "type": .string("runtime-request.respond"), "commandId": .string(commandId),
                "threadId": .string(threadId), "requestId": .string(requestId),
                "answers": .object(answers),
            ]
        case let .turnInterrupt(commandId, threadId, runId, _):
            guard let runId else { throw T3HTTPError.dispatchRejected }
            payload = [
                "type": .string("run.interrupt"), "commandId": .string(commandId),
                "threadId": .string(threadId), "runId": .string(runId),
            ]
        }
    }
}

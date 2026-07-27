import Foundation

// MARK: - Shell snapshot

public struct ShellSnapshot: Codable, Sendable, Equatable {
    public var snapshotSequence: Int
    public var projects: [ProjectShell]
    public var threads: [ThreadShell]
    public var updatedAt: String

    public init(
        snapshotSequence: Int,
        projects: [ProjectShell],
        threads: [ThreadShell],
        updatedAt: String
    ) {
        self.snapshotSequence = snapshotSequence
        self.projects = projects
        self.threads = threads
        self.updatedAt = updatedAt
    }
}

public struct ProjectShell: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var workspaceRoot: String?
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        id: String,
        title: String,
        workspaceRoot: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.workspaceRoot = workspaceRoot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ModelSelection: Codable, Sendable, Equatable {
    public var instanceId: String?
    public var provider: String?
    public var model: String

    public init(instanceId: String? = nil, provider: String? = nil, model: String) {
        self.instanceId = instanceId
        self.provider = provider
        self.model = model
    }

    public var displayName: String { model }
}

public struct Session: Codable, Sendable, Equatable {
    public var threadId: String?
    public var status: String
    public var providerName: String?
    public var providerInstanceId: String?
    public var runtimeMode: String?
    public var activeTurnId: String?
    public var lastError: String?
    public var updatedAt: String?

    public init(
        threadId: String? = nil,
        status: String,
        providerName: String? = nil,
        providerInstanceId: String? = nil,
        runtimeMode: String? = nil,
        activeTurnId: String? = nil,
        lastError: String? = nil,
        updatedAt: String? = nil
    ) {
        self.threadId = threadId
        self.status = status
        self.providerName = providerName
        self.providerInstanceId = providerInstanceId
        self.runtimeMode = runtimeMode
        self.activeTurnId = activeTurnId
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

public struct LatestTurn: Codable, Sendable, Equatable {
    public var turnId: String
    public var state: String
    public var requestedAt: String?
    public var startedAt: String?
    public var completedAt: String?
    public var assistantMessageId: String?

    public init(
        turnId: String,
        state: String,
        requestedAt: String? = nil,
        startedAt: String? = nil,
        completedAt: String? = nil,
        assistantMessageId: String? = nil
    ) {
        self.turnId = turnId
        self.state = state
        self.requestedAt = requestedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.assistantMessageId = assistantMessageId
    }
}

public struct ThreadShell: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var projectId: String
    public var title: String
    public var modelSelection: ModelSelection
    public var runtimeMode: String?
    public var interactionMode: String?
    public var branch: String?
    public var worktreePath: String?
    public var latestTurn: LatestTurn?
    public var createdAt: String?
    public var updatedAt: String
    public var archivedAt: String?
    public var settledAt: String?
    public var session: Session?
    public var latestUserMessageAt: String?
    public var hasPendingApprovals: Bool
    public var hasPendingUserInput: Bool
    public var hasActionableProposedPlan: Bool?

    public init(
        id: String,
        projectId: String,
        title: String,
        modelSelection: ModelSelection,
        runtimeMode: String? = nil,
        interactionMode: String? = nil,
        branch: String? = nil,
        worktreePath: String? = nil,
        latestTurn: LatestTurn? = nil,
        createdAt: String? = nil,
        updatedAt: String,
        archivedAt: String? = nil,
        settledAt: String? = nil,
        session: Session? = nil,
        latestUserMessageAt: String? = nil,
        hasPendingApprovals: Bool = false,
        hasPendingUserInput: Bool = false,
        hasActionableProposedPlan: Bool? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.modelSelection = modelSelection
        self.runtimeMode = runtimeMode
        self.interactionMode = interactionMode
        self.branch = branch
        self.worktreePath = worktreePath
        self.latestTurn = latestTurn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.settledAt = settledAt
        self.session = session
        self.latestUserMessageAt = latestUserMessageAt
        self.hasPendingApprovals = hasPendingApprovals
        self.hasPendingUserInput = hasPendingUserInput
        self.hasActionableProposedPlan = hasActionableProposedPlan
    }
}

// MARK: - Thread detail

public struct ThreadDetailSnapshot: Codable, Sendable, Equatable {
    public var snapshotSequence: Int
    public var thread: ThreadDetail

    public init(snapshotSequence: Int, thread: ThreadDetail) {
        self.snapshotSequence = snapshotSequence
        self.thread = thread
    }
}

public struct ThreadDetail: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var projectId: String
    public var title: String
    public var modelSelection: ModelSelection
    public var runtimeMode: String?
    public var interactionMode: String?
    public var branch: String?
    public var worktreePath: String?
    public var latestTurn: LatestTurn?
    public var createdAt: String?
    public var updatedAt: String
    public var messages: [ThreadMessage]
    public var activities: [ThreadActivity]
    public var session: Session?

    public init(
        id: String,
        projectId: String,
        title: String,
        modelSelection: ModelSelection,
        runtimeMode: String? = nil,
        interactionMode: String? = nil,
        branch: String? = nil,
        worktreePath: String? = nil,
        latestTurn: LatestTurn? = nil,
        createdAt: String? = nil,
        updatedAt: String,
        messages: [ThreadMessage] = [],
        activities: [ThreadActivity] = [],
        session: Session? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.modelSelection = modelSelection
        self.runtimeMode = runtimeMode
        self.interactionMode = interactionMode
        self.branch = branch
        self.worktreePath = worktreePath
        self.latestTurn = latestTurn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.activities = activities
        self.session = session
    }
}

public struct ThreadMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var role: String
    public var text: String
    public var turnId: String?
    public var streaming: Bool?
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        id: String,
        role: String,
        text: String,
        turnId: String? = nil,
        streaming: Bool? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.turnId = turnId
        self.streaming = streaming
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ThreadActivity: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var tone: String?
    public var kind: String
    public var summary: String
    public var payload: JSONValue?
    public var turnId: String?
    public var sequence: Int?
    public var createdAt: String

    public init(
        id: String,
        tone: String? = nil,
        kind: String,
        summary: String,
        payload: JSONValue? = nil,
        turnId: String? = nil,
        sequence: Int? = nil,
        createdAt: String
    ) {
        self.id = id
        self.tone = tone
        self.kind = kind
        self.summary = summary
        self.payload = payload
        self.turnId = turnId
        self.sequence = sequence
        self.createdAt = createdAt
    }
}

// MARK: - Environment descriptor

public struct EnvironmentDescriptor: Codable, Sendable, Equatable {
    public var environmentId: String?
    public var label: String?
    public var platform: EnvironmentPlatform?
    public var serverVersion: String?
    public var auth: AuthDescriptor?

    public init(
        environmentId: String? = nil,
        label: String? = nil,
        platform: EnvironmentPlatform? = nil,
        serverVersion: String? = nil,
        auth: AuthDescriptor? = nil
    ) {
        self.environmentId = environmentId
        self.label = label
        self.platform = platform
        self.serverVersion = serverVersion
        self.auth = auth
    }
}

public struct EnvironmentPlatform: Codable, Sendable, Equatable {
    public var os: String?
    public var arch: String?

    public init(os: String? = nil, arch: String? = nil) {
        self.os = os
        self.arch = arch
    }

    /// "macOS · arm64" style label for the notch header.
    public var displayName: String? {
        let osLabel: String? = switch os {
        case "darwin": "macOS"
        case "win32": "Windows"
        case "linux": "Linux"
        case let other: other
        }
        return [osLabel, arch].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
            .nilIfEmpty
    }
}

extension String {
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct AuthDescriptor: Codable, Sendable, Equatable {
    public var policy: String?
    public var bootstrapMethods: [String]?
    public var sessionMethods: [String]?
    public var sessionCookieName: String?

    public init(
        policy: String? = nil,
        bootstrapMethods: [String]? = nil,
        sessionMethods: [String]? = nil,
        sessionCookieName: String? = nil
    ) {
        self.policy = policy
        self.bootstrapMethods = bootstrapMethods
        self.sessionMethods = sessionMethods
        self.sessionCookieName = sessionCookieName
    }
}

// MARK: - Dispatch

public enum ApprovalDecision: String, Codable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

public enum DispatchCommand: Encodable, Sendable {
    case approvalRespond(
        commandId: String,
        threadId: String,
        requestId: String,
        decision: ApprovalDecision,
        createdAt: String
    )
    case userInputRespond(
        commandId: String,
        threadId: String,
        requestId: String,
        answers: [String: JSONValue],
        createdAt: String
    )
    case turnInterrupt(
        commandId: String,
        threadId: String,
        turnId: String?,
        createdAt: String
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case commandId
        case threadId
        case requestId
        case decision
        case answers
        case turnId
        case createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .approvalRespond(commandId, threadId, requestId, decision, createdAt):
            try container.encode("thread.approval.respond", forKey: .type)
            try container.encode(commandId, forKey: .commandId)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(decision, forKey: .decision)
            try container.encode(createdAt, forKey: .createdAt)
        case let .userInputRespond(commandId, threadId, requestId, answers, createdAt):
            try container.encode("thread.user-input.respond", forKey: .type)
            try container.encode(commandId, forKey: .commandId)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(answers, forKey: .answers)
            try container.encode(createdAt, forKey: .createdAt)
        case let .turnInterrupt(commandId, threadId, turnId, createdAt):
            try container.encode("thread.turn.interrupt", forKey: .type)
            try container.encode(commandId, forKey: .commandId)
            try container.encode(threadId, forKey: .threadId)
            try container.encodeIfPresent(turnId, forKey: .turnId)
            try container.encode(createdAt, forKey: .createdAt)
        }
    }
}

public struct DispatchResult: Codable, Sendable, Equatable {
    public var sequence: Int?
    public var accepted: Bool?
    public var ok: Bool?

    public init(sequence: Int? = nil, accepted: Bool? = nil, ok: Bool? = nil) {
        self.sequence = sequence
        self.accepted = accepted
        self.ok = ok
    }
}

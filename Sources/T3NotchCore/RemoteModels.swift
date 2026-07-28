import Foundation

public struct EnvironmentID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ScopedThreadID: Hashable, Codable, Sendable {
    public let environmentID: EnvironmentID
    public let threadID: String

    public init(environmentID: EnvironmentID, threadID: String) {
        self.environmentID = environmentID
        self.threadID = threadID
    }

    public var storageKey: String {
        Data(environmentID.rawValue.utf8).base64URLEncodedString()
            + "."
            + Data(threadID.utf8).base64URLEncodedString()
    }
}

public struct ScopedProjectID: Hashable, Codable, Sendable {
    public let environmentID: EnvironmentID
    public let projectID: String

    public init(environmentID: EnvironmentID, projectID: String) {
        self.environmentID = environmentID
        self.projectID = projectID
    }

    public var storageKey: String {
        Data(environmentID.rawValue.utf8).base64URLEncodedString()
            + "."
            + Data(projectID.utf8).base64URLEncodedString()
    }
}

public struct ScopedRequestID: Hashable, Sendable {
    public let thread: ScopedThreadID
    public let requestID: String

    public init(thread: ScopedThreadID, requestID: String) {
        self.thread = thread
        self.requestID = requestID
    }
}

public enum EnvironmentSource: String, Codable, Sendable, CaseIterable {
    case local
    case direct
    case t3Connect
}

public struct EnvironmentProfile: Identifiable, Codable, Sendable, Equatable {
    public let environmentID: EnvironmentID
    public var label: String
    public var directEndpoint: ServerEndpoint?
    public var source: EnvironmentSource
    public var enabled: Bool
    public var allowsInsecureHTTP: Bool

    public var id: EnvironmentID { environmentID }

    public init(
        environmentID: EnvironmentID,
        label: String,
        directEndpoint: ServerEndpoint? = nil,
        source: EnvironmentSource,
        enabled: Bool = true,
        allowsInsecureHTTP: Bool = false
    ) {
        self.environmentID = environmentID
        self.label = label
        self.directEndpoint = directEndpoint
        self.source = source
        self.enabled = enabled
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }
}

public enum EnvironmentConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case offline(String?)
    case unauthorized
    case needsPairing
    case credentialLocked
    case incompatible(String)
}

public struct EnvironmentSnapshot: Sendable {
    public let profile: EnvironmentProfile
    public let descriptor: EnvironmentDescriptor?
    public let connectionState: EnvironmentConnectionState
    public let activeAccessPath: EnvironmentSource
    public let shell: ShellSnapshot?

    public init(
        profile: EnvironmentProfile,
        descriptor: EnvironmentDescriptor?,
        connectionState: EnvironmentConnectionState,
        activeAccessPath: EnvironmentSource,
        shell: ShellSnapshot?
    ) {
        self.profile = profile
        self.descriptor = descriptor
        self.connectionState = connectionState
        self.activeAccessPath = activeAccessPath
        self.shell = shell
    }
}

public enum EnvironmentEvent: Sendable {
    case snapshot(EnvironmentSnapshot)
    case detail(ScopedThreadID, ThreadDetailSnapshot)
    case removed(EnvironmentID)
}

import Foundation

/// Builds the aggregate the app runs on. The namespace rules live here so the
/// app layer never has to know that T3 is the default (unprefixed) child.
public enum TransportFactory {
    public static let claudeNamespace = "claude"
    public static let codexNamespace = "codex"

    public static func makeAggregate(
        t3: (any AgentTransport)?,
        enableClaude: Bool,
        enableCodex: Bool,
        hookServer: ClaudeHookServer? = nil
    ) -> AggregatingTransport {
        var children: [AggregatingTransport.Child] = []
        if let t3 {
            children.append(AggregatingTransport.Child(transport: t3, namespace: nil))
        }
        if enableClaude {
            children.append(
                AggregatingTransport.Child(
                    transport: ClaudeCodeTransport(hookServer: hookServer),
                    namespace: claudeNamespace
                )
            )
        }
        if enableCodex {
            children.append(
                AggregatingTransport.Child(
                    transport: CodexTransport(),
                    namespace: codexNamespace
                )
            )
        }
        return AggregatingTransport(children: children)
    }

    /// Namespace an `AgentSource` occupies in the aggregate; `nil` for T3, whose
    /// ids pass through unprefixed.
    public static func namespace(for source: AgentSource) -> String? {
        switch source {
        case .t3: return nil
        case .claude: return claudeNamespace
        case .codex: return codexNamespace
        }
    }
}

import AinkradAppKit
import Foundation

/// Publishes Leyline's connection catalogue to the host assistant as MCP tools.
///
/// The shape follows Lore's `LoreMCPServer` and Git Mage's `GitMageMCPServer` —
/// a declarative tool table, `[GuardRule]` arrays for `rejects`/`injects`, and a
/// `make` that accumulates `addTool` failures — because that pattern encodes
/// safety properties that are not app-specific. Leyline is the fourth adopter,
/// and the two things it does differently are both consequences of what it
/// stores:
///
/// 1. **The tool set is tiny and read-heavy on purpose.** Leyline's store holds
///    credentials, so the interesting design question was not "what can we
///    publish" but "what must we not". Nothing that mutates the connection or
///    key store is published, and nothing that takes or returns credential
///    material exists at all — see `LeylineMCPOperations` and `LeylineCatalog`.
/// 2. **`rejects` and `injects` are empty across the whole table**, and that is
///    the honest state rather than an oversight. Those arrays exist to split one
///    operation into a guarded tool and a `destructive: true` twin when an
///    ARGUMENT decides irreversibility — `overwritingExternalChanges` in Lore,
///    `reset`/`reset_hard` in Git Mage. Leyline has no such argument: `connect`
///    takes one connection id and nothing else, and its consequence is fixed by
///    the tool, not by what the caller passes. The machinery is kept so the
///    fourth adopter reads like the first three and so a future guarded
///    argument has somewhere to go, but it is currently carrying no weight.
///
/// ## Destructive classification
///
/// `destructive` is what the host's Full-auto guard gates on.
///
/// - `list_connections`, `list_keys` — `readOnly: true`. They read a store the
///   plugin already holds in memory and touch nothing.
/// - `connect` — **`destructive: true`.** This is a judgement call and it is
///   worth stating plainly, because `connect` is not irreversible in the data
///   sense: it opens a Rune window, and closing it undoes everything on
///   THIS machine. The reason it is gated anyway is that the consequence is not
///   on this machine. It opens an authenticated session to a REMOTE host, using
///   credentials the user stored, on the user's behalf — the same reasoning
///   that gated `pr_merge` and `pr_approve` in Git Mage, neither of which
///   destroys local data either. What a shell on the far end then does is
///   outside Ainkrad's ability to undo or even observe. An agent should need a
///   human to say yes before it does that.
///
/// ## `requiresLiveApp` is false on all three — and this is easy to get backwards
///
/// That flag means "this tool needs LEYLINE'S OWN WINDOW on screen", i.e. it
/// drives live view state rather than a store the app owns headlessly. Leyline's
/// store is constructed from `host.documents` and `host.secrets` in
/// `LeylineApp.store(for:)` and works perfectly with no window, so both list
/// tools are plainly headless.
///
/// `connect` is the one that invites the wrong answer, because it visibly opens
/// a window — but it opens **Rune's** window, through `host.apps`, and the
/// host launches that app itself. Setting the flag would force Leyline's window
/// open too: an unrelated second window appearing every time the assistant
/// connects, for no reason. The flag is about the CALLEE's window, never the
/// callee's side effects.
@MainActor
enum LeylineMCPServer {
    /// One published tool.
    struct Tool {
        /// The MCP tool name (snake_case, MCP convention).
        let name: String
        /// The operation token forwarded to `LeylineMCPOperations`.
        let operation: String
        let summary: String
        /// Surfaced as `destructiveHint`; the host gates these on approval.
        let destructive: Bool
        let readOnly: Bool
        /// The tool's JSON Schema, as a literal JSON string. A string rather
        /// than `[String: Any]` because the table is a `static let` and `Any`
        /// is not `Sendable`; `MCPToolSpec` wants a string anyway.
        let schemaJSON: String

        /// Argument keys this tool must refuse, so an irreversible behaviour
        /// stays unreachable through a tool the host does not gate. The call is
        /// refused if **ANY** rule matches — the safe direction, since adding a
        /// rule only narrows what gets through.
        ///
        /// Empty for every Leyline tool today; see this enum's doc comment for
        /// why, and note that an exact-match rule is only sound when it mirrors
        /// its sink's coercion exactly.
        var rejects: [GuardRule] = []

        /// Argument keys this tool sets itself, ignoring what was passed. **ALL**
        /// listed values are injected — a destructive twin owns every argument
        /// its safe counterpart refuses. Empty for every Leyline tool today.
        var injects: [GuardRule] = []

        init(
            _ name: String, _ operation: String, _ summary: String,
            destructive: Bool = false, readOnly: Bool = false,
            schemaJSON: String,
            rejects: [GuardRule] = [],
            injects: [GuardRule] = []
        ) {
            self.name = name
            self.operation = operation
            self.summary = summary
            self.destructive = destructive
            self.readOnly = readOnly
            self.schemaJSON = schemaJSON
            self.rejects = rejects
            self.injects = injects
        }
    }

    /// One guarded argument key/value pair.
    struct GuardRule {
        let key: String
        let value: ArgumentValue
        init(_ key: String, _ value: ArgumentValue) {
            self.key = key
            self.value = value
        }
    }

    /// The argument shapes the reject/inject rules need. Exact matches, sound
    /// only when their sinks are exact too.
    enum ArgumentValue {
        case string(String)
        case bool(Bool)

        /// Whether a value decoded from the call's arguments equals this one.
        func matches(_ any: Any) -> Bool {
            switch self {
            case .string(let s): return (any as? String) == s
            case .bool(let b): return (any as? Bool) == b
            }
        }

        var foundation: Any {
            switch self {
            case .string(let s): return s
            case .bool(let b): return b
            }
        }

        var described: String {
            switch self {
            case .string(let s): return "\"\(s)\""
            case .bool(let b): return "\(b)"
            }
        }
    }

    // MARK: - the table

    static let tools: [Tool] = [
        Tool(
            "list_connections", "listConnections",
            "List the SSH hosts saved in Leyline. Returns each connection's id, label, "
                + "username, host, port and which authentication method it uses. Never returns "
                + "passwords, private keys or passphrases — those cannot be read from here at "
                + "all. Pass the returned label to connect (the id also works, and is needed "
                + "only when two connections share a label).",
            readOnly: true,
            schemaJSON: schema(
                properties: [
                    (
                        "query", "string",
                        "Optional case-insensitive filter over label, host and username. "
                            + "Omit to list every saved connection."
                    )
                ], required: [])),

        Tool(
            "list_keys", "listKeys",
            "List the SSH keys imported into Leyline's vault, by id and label only. Key "
                + "material and passphrases are held in the Keychain and are not readable "
                + "through any tool. Use this to tell the user which key a connection uses, "
                + "not to obtain a key.",
            readOnly: true,
            schemaJSON: schema(properties: [], required: [])),

        Tool(
            "connect", "connect",
            "Open a Rune session to a saved connection. This starts an "
                + "authenticated SSH session to a REMOTE machine using the user's stored "
                + "credentials, so it needs approval. Call list_connections first, then pass "
                + "the connection's label — the label is what the user reads on the approval "
                + "card. Use the id only when two connections share a label. A hostname is "
                + "never accepted.",
            destructive: true,
            schemaJSON: schema(
                properties: [
                    (
                        "connection", "string",
                        "The connection's label, exactly as returned by list_connections — "
                            + "prefer the label so the approval prompt names a machine the user "
                            + "recognises. The id is also accepted, and is required when two "
                            + "connections share the same label."
                    )
                ], required: ["connection"])),
    ]

    // MARK: - assembly

    /// Builds the server. `perform` receives a JSON object string of the shape
    /// `{"operation": ..., <the call's arguments>}` — in production
    /// `LeylineMCPOperations.run`.
    ///
    /// Returns the names of any tools `addTool` refused alongside the server: a
    /// dropped tool is a silently missing capability, so the caller must not be
    /// able to ignore it by accident.
    static func make(
        appID: String,
        perform: @escaping @MainActor @Sendable (String) async -> AgentActionResult
    )
        -> (server: MCPAppServer, failures: [String])
    {
        let server = MCPAppServer(appID: appID)
        var failures: [String] = []
        for tool in tools {
            // `requiresLiveApp` is left at its default `false` for every tool —
            // see this enum's doc comment. It is a settable `var` rather than an
            // `init` parameter for ABI reasons, so "not set" is the way to say
            // false, and saying it explicitly would be the same instruction.
            let added = server.addTool(
                MCPToolSpec(
                    name: tool.name,
                    description: tool.summary,
                    schemaJSON: tool.schemaJSON,
                    destructive: tool.destructive,
                    readOnly: tool.readOnly,
                    handler: { arguments in await invoke(tool, arguments: arguments, perform: perform) }
                ))
            if !added { failures.append(tool.name) }
        }
        return (server, failures)
    }

    // MARK: - call handling

    /// Internal rather than `private` so the tests can drive a test-only guarded
    /// `Tool` fixture through the real gate/inject logic without bending the
    /// live `tools` table (which has no guards today).
    static func invoke(
        _ tool: Tool, arguments: String,
        perform: @MainActor @Sendable (String) async -> AgentActionResult
    )
        async -> AgentActionResult
    {
        guard let data = arguments.data(using: .utf8),
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return AgentActionResult(text: "\(tool.name): malformed arguments", isError: true)
        }

        // The gate: a behaviour the host treats as needing approval must not be
        // reachable through a tool it does not gate. ANY matching rule refuses.
        for rule in tool.rejects {
            guard let passed = object[rule.key], rule.value.matches(passed) else { continue }
            return AgentActionResult(
                text: "\(tool.name) refuses \(rule.key) = \(rule.value.described) — "
                    + "it needs approval. Use the dedicated tool instead.",
                isError: true)
        }
        // ALL injected values are applied — a destructive twin owns every
        // argument its safe counterpart refuses.
        for rule in tool.injects { object[rule.key] = rule.value.foundation }

        object["operation"] = tool.operation
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else {
            return AgentActionResult(text: "\(tool.name): could not encode the request", isError: true)
        }
        return await perform(String(decoding: payload, as: UTF8.self))
    }

    // MARK: - schema

    /// Builds a tool's JSON Schema string from a flat property list. Returns a
    /// string so the tool table stays a `Sendable` `static let`.
    private static func schema(
        properties: [(String, String, String)],
        required: [String]
    ) -> String {
        var props: [String: Any] = [:]
        for (name, type, description) in properties {
            props[name] = ["type": type, "description": description]
        }
        let schema: [String: Any] = ["type": "object", "properties": props, "required": required]
        guard let data = try? JSONSerialization.data(withJSONObject: schema) else {
            return #"{"type":"object"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

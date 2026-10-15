import SwiftUI

/// The coding agents Docker Sandboxes ships workloads for
/// (https://docs.docker.com/ai/sandboxes/agents/).
enum Agent: CaseIterable {
    case claude
    case codex
    case copilot
    case cursor
    case devin
    case dockerAgent
    case droid
    case gemini
    case kiro
    case openCode
    case shell

    /// Recognizes an agent from whatever `sbx ls --json` reports for it: the
    /// agent name (`claude`), a kit (`docker/sbx-kit-claude`) or a template
    /// image (`docker/sandbox-templates:claude-code`).
    init?(identifier: String?) {
        guard let identifier = identifier?.lowercased(), !identifier.isEmpty else { return nil }
        // Every Docker image name contains "docker", so match Docker Agent on
        // its full name before splitting into words.
        if identifier.contains("docker-agent") || identifier.contains("dockeragent") || identifier.contains("cagent") {
            self = .dockerAgent
            return
        }
        let words = Set(identifier.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard let agent = Self.allCases.first(where: { !words.isDisjoint(with: $0.keywords) }) else {
            return nil
        }
        self = agent
    }

    private var keywords: Set<String> {
        switch self {
        case .claude: ["claude"]
        case .codex: ["codex", "openai"]
        case .copilot: ["copilot"]
        case .cursor: ["cursor"]
        case .devin: ["devin"]
        case .dockerAgent: []
        case .droid: ["droid", "factory"]
        case .gemini: ["gemini"]
        case .kiro: ["kiro"]
        case .openCode: ["opencode"]
        case .shell: ["shell"]
        }
    }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot"
        case .cursor: "Cursor"
        case .devin: "Devin"
        case .dockerAgent: "Docker Agent"
        case .droid: "Droid"
        case .gemini: "Gemini"
        case .kiro: "Kiro"
        case .openCode: "OpenCode"
        case .shell: "Shell"
        }
    }

    /// The agent's logo in the asset catalog, from Simple Icons (CC0). Agents
    /// without one there use an SF Symbol instead.
    fileprivate var image: Image {
        switch self {
        case .claude: Image("AgentClaude")
        case .codex: Image("AgentCodex")
        case .copilot: Image("AgentCopilot")
        case .cursor: Image("AgentCursor")
        case .dockerAgent: Image("AgentDocker")
        case .gemini: Image("AgentGemini")
        case .openCode: Image("AgentOpenCode")
        case .devin, .droid, .kiro: Image(systemName: "sparkles")
        case .shell: Image(systemName: "terminal")
        }
    }

    /// Brand colors that read in both light and dark mode. Black logos are
    /// left to the surrounding style.
    var color: Color? {
        switch self {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .dockerAgent: Color(red: 0x24 / 255, green: 0x96 / 255, blue: 0xED / 255)
        case .gemini: Color(red: 0x8E / 255, green: 0x75 / 255, blue: 0xB2 / 255)
        default: nil
        }
    }
}

extension Sandbox {
    var knownAgent: Agent? { Agent(identifier: agent) }
}

/// The sandbox's agent logo, or a box when the agent isn't recognized.
struct AgentIcon: View {
    let agent: Agent?
    var size: CGFloat = 16
    /// Uses the filled box for unrecognized agents.
    var filled = false

    var body: some View {
        (agent?.image ?? Image(systemName: filled ? "shippingbox.fill" : "shippingbox"))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .help(agent?.displayName ?? "")
    }
}

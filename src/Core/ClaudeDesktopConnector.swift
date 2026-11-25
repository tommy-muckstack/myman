import Foundation
import SwiftUI

/// Adds MyMan's walkthrough server to the Claude desktop app's MCP config, and removes it again.
/// It only touches the `myman` entry. An existing config that cannot be parsed is left alone.
enum ClaudeDesktopConnector {
    static let serverName = "myman"

    enum Status: Equatable {
        case notConnected, connected, needsUpdate, nodeMissing
    }

    enum ConnectError: LocalizedError {
        case nodeMissing, scriptMissing, configUnreadable
        var errorDescription: String? {
            switch self {
            case .nodeMissing: return "Install Node.js 22 or newer, then connect again."
            case .scriptMissing: return "This copy of MyMan does not include the walkthrough server. Reinstall MyMan."
            case .configUnreadable: return "Claude desktop's settings file could not be read, so it was left as it is. Fix or move it, then try again."
            }
        }
    }

    /// Overridable so tests can use a temporary file.
    static var configURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")

    static func serverScript() -> URL? {
        Bundle.module.url(forResource: "BrainCompanion", withExtension: nil)?.appendingPathComponent("walkthrough-mcp.mjs")
    }

    /// Claude desktop starts with a short PATH, so the config stores the absolute path to Node 22 or newer.
    static func nodePath() -> String? {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        let fromShell = run("/bin/zsh", ["-lc", "command -v node"]).flatMap { $0.isEmpty ? nil : $0 }
        let paths = (fromShell.map { [$0] } ?? []) + candidates
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let major = run(path, ["-p", "process.versions.node.split('.')[0]"]).flatMap { Int($0) } ?? 0
            if major >= 22 { return path }
        }
        return nil
    }

    static func status() -> Status {
        guard let node = nodePath() else { return .nodeMissing }
        guard let entry = readConfig()?["mcpServers"] as? [String: Any], let server = entry[serverName] as? [String: Any] else {
            return .notConnected
        }
        let script = serverScript()?.path
        let args = server["args"] as? [String] ?? []
        return (server["command"] as? String == node && args == [script].compactMap { $0 }) ? .connected : .needsUpdate
    }

    static func connect() throws {
        guard let node = nodePath() else { throw ConnectError.nodeMissing }
        guard let script = serverScript() else { throw ConnectError.scriptMissing }
        try writeServer(command: node, script: script.path)
    }

    static func disconnect() throws {
        try removeServer()
    }

    /// Sets the `myman` entry and leaves every other key as it was.
    static func writeServer(command: String, script: String) throws {
        var config = try loadConfig()
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": command, "args": [script]]
        config["mcpServers"] = servers
        try saveConfig(config)
    }

    static func removeServer() throws {
        var config = try loadConfig()
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: serverName)
        config["mcpServers"] = servers
        try saveConfig(config)
    }

    private static func readConfig() -> [String: Any]? {
        try? loadConfig()
    }

    /// A missing file is an empty config. A file that exists but does not parse is an error, so it is never overwritten.
    private static func loadConfig() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return [:] }
        let data = try Data(contentsOf: configURL)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectError.configUnreadable }
        return object
    }

    private static func saveConfig(_ config: [String: Any]) throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The Agents card that connects MyMan to the Claude desktop app, so one click makes narration available there.
struct ClaudeDesktopConnectionCard: View {
    @State private var status: ClaudeDesktopConnector.Status = .notConnected
    @State private var message: String?

    private var statusText: String {
        switch status {
        case .connected: return "Connected. Claude desktop can start walkthrough recordings. Restart Claude desktop if it was open."
        case .notConnected: return "Not connected. Connecting adds MyMan's recording tools to Claude desktop."
        case .needsUpdate: return "The connection points at an older copy of MyMan. Connect again to update it."
        case .nodeMissing: return "Needs Node.js 22 or newer. Install it, then check again."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude desktop").font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
            Text(statusText).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            HStack(spacing: 8) {
                Button(status == .connected ? "Disconnect" : "Connect to Claude desktop") { toggle() }
                    .clickable()
                    .disabled(status == .nodeMissing)
                Button("Check again") { refresh() }.clickable()
            }
            if let message { Text(message).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(MM.Colors.surface))
        .onAppear { refresh() }
    }

    private func refresh() {
        status = ClaudeDesktopConnector.status()
        message = nil
    }

    private func toggle() {
        let wasConnected = status == .connected
        do {
            if wasConnected { try ClaudeDesktopConnector.disconnect() } else { try ClaudeDesktopConnector.connect() }
            message = wasConnected ? "Disconnected." : "Connected. Restart Claude desktop to see MyMan's tools."
        } catch {
            message = error.localizedDescription
        }
        status = ClaudeDesktopConnector.status()
    }
}

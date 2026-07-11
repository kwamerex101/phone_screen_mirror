// Which MCP server the installer is acting on. `device` drives a physical iPhone
// (WDA on 8100, no env); `simulator` drives a booted Simulator (WDA on 8101, with
// IMIRROR_TARGET=simulator so the server takes its simulator code paths). Kept in
// iMirrorCore so the profile/env values are unit-testable.

import Foundation

public struct MCPProfile: Sendable, Equatable {
    public let serverName: String
    public let env: [String: String]

    public init(serverName: String, env: [String: String]) {
        self.serverName = serverName
        self.env = env
    }

    public static let device = MCPProfile(serverName: "imirror", env: [:])
    public static let simulator = MCPProfile(
        serverName: "imirror-sim",
        env: ["IMIRROR_TARGET": "simulator",
              "IMIRROR_WDA": "http://127.0.0.1:8101"])
}

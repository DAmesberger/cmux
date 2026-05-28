import Foundation
import OSLog
import GhosttyKit

private let log = Logger(subsystem: "com.cmux", category: "WorkspaceRemoteConfiguration")

private enum WorkspaceRemoteSSHOptionFilter {
    private static let transientControlSocketKeys: Set<String> = [
        "controlmaster",
        "controlpath",
        "controlpersist",
    ]

    static func durableOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.filter { option in
            guard let key = optionKey(option) else { return true }
            return !transientControlSocketKeys.contains(key)
        }
    }

    static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedIdentityPath(_ value: String?) -> String? {
        guard let trimmed = normalizedOptional(value) else { return nil }
        guard trimmed.hasPrefix("~") else { return trimmed }
        return normalizedOptional((trimmed as NSString).expandingTildeInPath) ?? trimmed
    }

    static func hasOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        return options.contains { option in
            optionKey(option) == loweredKey
        }
    }

    static func optionValue(_ key: String, in option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0.isWhitespace })
        guard parts.count == 2 else { return nil }
        guard parts[0].lowercased() == key.lowercased() else { return nil }
        return String(parts[1])
    }

    private static func optionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }
}

nonisolated struct SessionRemoteWorkspaceSnapshot: Codable, Equatable, Sendable {
    var destination: String
    var port: Int?
    var identityFile: String?
    var sshOptions: [String]
    var groupID: UUID?
    var keepaliveIntervalMs: UInt32?
    var maxReconnectAttempts: UInt32?
    var reconnectIntervalMs: UInt32?
    var reconnectMaxIntervalMs: UInt32?
    var sessionColor: Int8?
    var sessionLabel: String?
}

struct WorkspaceRemoteConfiguration: Equatable {
    static func == (lhs: WorkspaceRemoteConfiguration, rhs: WorkspaceRemoteConfiguration) -> Bool {
        lhs.destination == rhs.destination &&
        lhs.port == rhs.port &&
        lhs.identityFile == rhs.identityFile &&
        lhs.sshOptions == rhs.sshOptions &&
        lhs.groupID == rhs.groupID &&
        lhs.keepaliveIntervalMs == rhs.keepaliveIntervalMs &&
        lhs.maxReconnectAttempts == rhs.maxReconnectAttempts &&
        lhs.reconnectIntervalMs == rhs.reconnectIntervalMs &&
        lhs.reconnectMaxIntervalMs == rhs.reconnectMaxIntervalMs &&
        lhs.sessionColor == rhs.sessionColor &&
        lhs.sessionLabel == rhs.sessionLabel
        // hostKeyPolicy excluded: .interactive case contains a non-Equatable closure
    }

    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
    /// Stable group identity for the remote session. Generated on first connection;
    /// persisted so the same daemon session reattaches across cmux restarts.
    let groupID: UUID
    let keepaliveIntervalMs: UInt32
    let maxReconnectAttempts: UInt32
    let reconnectIntervalMs: UInt32
    let reconnectMaxIntervalMs: UInt32
    let hostKeyPolicy: Ghostty.HostKeyHandler
    /// Color slot from the daemon session (-1 = none, 0-7 = palette slot).
    var sessionColor: Int8
    /// Daemon-side session label. Seeds customTitle on workspace creation.
    var sessionLabel: String?

    init(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        groupID: UUID = UUID(),
        keepaliveIntervalMs: UInt32 = CmuxResolvedSSHConfig.builtIn.keepAliveIntervalMs,
        maxReconnectAttempts: UInt32 = CmuxResolvedSSHConfig.builtIn.maxReconnectAttempts,
        reconnectIntervalMs: UInt32 = CmuxResolvedSSHConfig.builtIn.reconnectIntervalMs,
        reconnectMaxIntervalMs: UInt32 = CmuxResolvedSSHConfig.builtIn.reconnectMaxIntervalMs,
        hostKeyPolicy: Ghostty.HostKeyHandler = .tofu,
        sessionColor: Int8 = -1,
        sessionLabel: String? = nil
    ) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.groupID = groupID
        self.keepaliveIntervalMs = keepaliveIntervalMs
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectIntervalMs = reconnectIntervalMs
        self.reconnectMaxIntervalMs = reconnectMaxIntervalMs
        self.hostKeyPolicy = hostKeyPolicy
        self.sessionColor = sessionColor
        self.sessionLabel = sessionLabel
    }

    var displayTarget: String {
        guard let port else { return destination }
        return "\(destination):\(port)"
    }

    func ghosttyConfig() -> Ghostty.SSHConnection.Config {
        var target = destination
        if let port { target += ":\(port)" }

        let jump = sshOptions.compactMap { option -> String? in
            WorkspaceRemoteSSHOptionFilter.optionValue("ProxyJump", in: option)
        }.first ?? ""

        let resolvedIdentity: String
        if let explicit = WorkspaceRemoteSSHOptionFilter.normalizedIdentityPath(identityFile) {
            resolvedIdentity = explicit
        } else if let fromOptions = sshOptions.compactMap({ option -> String? in
            WorkspaceRemoteSSHOptionFilter.optionValue("IdentityFile", in: option)
        }).first {
            resolvedIdentity = WorkspaceRemoteSSHOptionFilter.normalizedIdentityPath(fromOptions) ?? fromOptions
        } else {
            resolvedIdentity = ""
        }

        for option in sshOptions {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let keyLower = trimmed
                .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
                .first
                .map { String($0).lowercased() } ?? ""
            guard keyLower != "proxyjump", keyLower != "identityfile" else { continue }
            log.info("SSH option dropped (not supported by libghostty): \(trimmed, privacy: .public)")
        }

        return Ghostty.SSHConnection.Config(
            target: target,
            jump: jump,
            identityFile: resolvedIdentity,
            keepaliveIntervalMs: keepaliveIntervalMs,
            maxReconnectAttempts: maxReconnectAttempts,
            reconnectIntervalMs: reconnectIntervalMs,
            reconnectMaxIntervalMs: reconnectMaxIntervalMs
        )
    }
}

extension SessionRemoteWorkspaceSnapshot {
    func workspaceConfiguration() -> WorkspaceRemoteConfiguration? {
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDestination.isEmpty else { return nil }
        let normalizedPort = port.flatMap { port in
            (1...65535).contains(port) ? port : nil
        }

        let fallback = CmuxResolvedSSHConfig.builtIn
        return WorkspaceRemoteConfiguration(
            destination: normalizedDestination,
            port: normalizedPort,
            identityFile: Self.normalizedIdentityPath(identityFile),
            sshOptions: Self.normalizedSSHOptions(sshOptions),
            groupID: groupID ?? UUID(),
            keepaliveIntervalMs: keepaliveIntervalMs ?? fallback.keepAliveIntervalMs,
            maxReconnectAttempts: maxReconnectAttempts ?? fallback.maxReconnectAttempts,
            reconnectIntervalMs: reconnectIntervalMs ?? fallback.reconnectIntervalMs,
            reconnectMaxIntervalMs: reconnectMaxIntervalMs ?? fallback.reconnectMaxIntervalMs,
            sessionColor: sessionColor ?? -1,
            sessionLabel: sessionLabel
        )
    }

    private static func normalizedIdentityPath(_ value: String?) -> String? {
        WorkspaceRemoteSSHOptionFilter.normalizedIdentityPath(value)
    }

    private static func normalizedSSHOptions(_ options: [String]) -> [String] {
        WorkspaceRemoteSSHOptionFilter.durableOptions(options)
    }
}

extension WorkspaceRemoteConfiguration {
    func sessionSnapshot() -> SessionRemoteWorkspaceSnapshot? {
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDestination.isEmpty else { return nil }

        return SessionRemoteWorkspaceSnapshot(
            destination: normalizedDestination,
            port: port,
            identityFile: WorkspaceRemoteSSHOptionFilter.normalizedIdentityPath(identityFile),
            sshOptions: WorkspaceRemoteSSHOptionFilter.durableOptions(sshOptions),
            groupID: groupID,
            keepaliveIntervalMs: keepaliveIntervalMs,
            maxReconnectAttempts: maxReconnectAttempts,
            reconnectIntervalMs: reconnectIntervalMs,
            reconnectMaxIntervalMs: reconnectMaxIntervalMs,
            sessionColor: sessionColor,
            sessionLabel: sessionLabel
        )
    }
}

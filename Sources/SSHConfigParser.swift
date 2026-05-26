import Foundation

/// Parsed entry from `~/.ssh/config` used to populate the SSH Connect host picker.
///
/// Each entry captures the user-visible Host alias plus the resolved HostName,
/// User, Port, and IdentityFile values. Wildcard host patterns (`Host *`,
/// `Host *.example.com`) are skipped because the picker only shows concrete
/// connection targets. ProxyJump and other directives are intentionally
/// ignored: the form only surfaces what the dialog can edit.
struct SSHConfigHost: Equatable, Hashable {
    let alias: String
    let hostName: String?
    let user: String?
    let port: Int?
    let identityFile: String?

    var resolvedHostName: String { hostName ?? alias }
}

enum SSHConfigParser {
    /// Reads and parses the user's `~/.ssh/config`. Returns an empty array when
    /// the file is missing, unreadable, or contains no concrete Host entries.
    static func loadUserConfig(fileManager: FileManager = .default) -> [SSHConfigHost] {
        let configURL = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let data = try? Data(contentsOf: configURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return parse(text)
    }

    /// Parses ssh_config(5)-style text. Block-scoped to each `Host` directive;
    /// `Match` blocks reset the current host scope so their directives don't
    /// leak into the previous concrete Host.
    static func parse(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var currentAliases: [String] = []
        var currentValues: [String: String] = [:]

        func flush() {
            guard !currentAliases.isEmpty else { return }
            let hostName = currentValues["hostname"]
            let user = currentValues["user"]
            let port = currentValues["port"].flatMap(Int.init)
            let identityFile = currentValues["identityfile"]
            for alias in currentAliases where !isWildcard(alias) {
                hosts.append(
                    SSHConfigHost(
                        alias: alias,
                        hostName: hostName,
                        user: user,
                        port: port,
                        identityFile: identityFile
                    )
                )
            }
            currentAliases = []
            currentValues = [:]
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (keyword, value) = splitDirective(line)
            guard let keyword else { continue }
            let lowerKeyword = keyword.lowercased()
            if lowerKeyword == "host" {
                flush()
                currentAliases = splitHostList(value)
                continue
            }
            if lowerKeyword == "match" {
                flush()
                continue
            }
            guard !currentAliases.isEmpty else { continue }
            currentValues[lowerKeyword] = value
        }
        flush()

        var seen = Set<String>()
        return hosts.filter { seen.insert($0.alias).inserted }
    }

    private static func splitDirective(_ line: String) -> (String?, String) {
        if let equalsIndex = line.firstIndex(of: "=") {
            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            return (key.isEmpty ? nil : key, stripQuotes(value))
        }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            return (String(parts[0]), stripQuotes(String(parts[1]).trimmingCharacters(in: .whitespaces)))
        }
        return (parts.first.map(String.init), "")
    }

    private static func splitHostList(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { stripQuotes(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first
        let last = value.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func isWildcard(_ alias: String) -> Bool {
        alias.contains("*") || alias.contains("?") || alias.hasPrefix("!")
    }
}

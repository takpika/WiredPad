import Foundation

/// Points SSH at WiredPad's agent in ~/.ssh/config, and puts it back. The `IdentityAgent` lines
/// that name another agent are switched to WiredPad's, which passes on to that agent whatever is
/// not the iPad's; each keeps its original on a comment line above it, so turning this off
/// restores the file as it was. Lines saying `none` stay as they are. Without any such line, a
/// block at the end gives every host WiredPad's agent.
enum SSHConfig {
    private static let agent = "~/.wiredpad/agent.sock"
    private static let marker = "# WiredPad replaced: "
    private static let blockStart = "# WiredPad begin"
    private static let blockEnd = "# WiredPad end"
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// The file itself when ~/.ssh/config links elsewhere, as it does with some dotfile managers.
    private static var file: URL {
        home.appendingPathComponent(".ssh/config").resolvingSymlinksInPath()
    }

    static var isEnabled: Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.contains(marker) || text.contains(blockStart)
    }

    /// The agent SSH used before, which WiredPad's passes the other keys on to.
    static var upstream: String? {
        UserDefaults.standard.string(forKey: "WiredPad.upstreamAgent")
    }

    static func enable() throws {
        guard !isEnabled else { return }
        let original = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = original.components(separatedBy: "\n")
        var replaced: String?
        var index = 0
        while index < lines.count {
            if let (indent, value) = agentLine(lines[index]),
               value.lowercased() != "none", value != agent, replaced == nil || value == replaced {
                replaced = value
                lines.insert(indent + marker + lines[index].trimmingCharacters(in: .whitespaces), at: index)
                lines[index + 1] = indent + "IdentityAgent " + agent
                index += 1
            }
            index += 1
        }
        var text = lines.joined(separator: "\n")
        if replaced == nil {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += "\n\(blockStart)\nHost *\n  IdentityAgent \(agent)\n\(blockEnd)\n"
        }
        if let replaced, replaced != "SSH_AUTH_SOCK" {
            let expanded = replaced.hasPrefix("~/") ? home.appendingPathComponent(String(replaced.dropFirst(2))).path : replaced
            UserDefaults.standard.set(expanded.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                                      forKey: "WiredPad.upstreamAgent")
        } else {
            UserDefaults.standard.removeObject(forKey: "WiredPad.upstreamAgent")
        }
        try write(text, backup: original)
    }

    static func disable() throws {
        guard let original = try? String(contentsOf: file, encoding: .utf8) else { return }
        var lines = original.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(marker), index + 1 < lines.count, agentLine(lines[index + 1]) != nil {
                let indent = String(lines[index].prefix { $0 == " " || $0 == "\t" })
                lines[index + 1] = indent + trimmed.dropFirst(marker.count)
                lines.remove(at: index)
                continue
            }
            if trimmed == blockStart, let end = lines[index...].firstIndex(of: blockEnd) {
                // The blank line the block was added after goes too.
                let start = index > 0 && lines[index - 1].isEmpty ? index - 1 : index
                lines.removeSubrange(start...end)
                index = start
                continue
            }
            index += 1
        }
        UserDefaults.standard.removeObject(forKey: "WiredPad.upstreamAgent")
        try write(lines.joined(separator: "\n"), backup: original)
    }

    /// The indentation and value of an `IdentityAgent` line.
    private static func agentLine(_ line: String) -> (String, String)? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        guard rest.lowercased().hasPrefix("identityagent") else { return nil }
        let value = rest.dropFirst("identityagent".count)
        guard let first = value.first, first == " " || first == "\t" || first == "=" else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        return trimmed.isEmpty ? nil : (indent, trimmed)
    }

    private static func write(_ text: String, backup: String) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !backup.isEmpty {
            let copy = directory.appendingPathComponent("config.wiredpad-backup")
            try backup.write(to: copy, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        }
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) as? Int ?? 0o600
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }
}

/// The sudo PAM module from the app's bundle, installed with PAM/install.sh. That changes
/// /etc/pam.d, which macOS lets a terminal's sudo do but not the app, even with administrator
/// rights, so the app gives the commands to run and reads the result.
enum SudoSetup {
    private static let module = "/Library/WiredPad/pam_wiredpad.so"
    private static var installedKey: URL { URL(fileURLWithPath: "/Library/WiredPad/keys/\(NSUserName()).pub") }

    enum State { case off, on, stale }

    /// On when sudo asks the iPad with the current key; stale when the installed key is an
    /// older one, after setting the keys up again.
    static var state: State {
        guard let pam = try? String(contentsOfFile: "/etc/pam.d/sudo_local", encoding: .utf8),
              pam.contains(module), FileManager.default.fileExists(atPath: module),
              let installed = try? Data(contentsOf: installedKey) else { return .off }
        return installed == (try? Data(contentsOf: DeviceSigner.sudoPublicKeyFile)) ? .on : .stale
    }

    /// The terminal command that installs the module and the current key, or nil when this
    /// build has no module in its bundle.
    static var installCommand: String? {
        guard let script = Bundle.main.url(forResource: "install-sudo", withExtension: "sh"),
              let module = Bundle.main.url(forResource: "pam_wiredpad", withExtension: "so") else { return nil }
        return "sudo \(quoted(script.path)) install --module \(quoted(module.path))"
    }

    static var uninstallCommand: String? {
        Bundle.main.url(forResource: "install-sudo", withExtension: "sh").map { "sudo \(quoted($0.path)) uninstall" }
    }

    private static func quoted(_ value: String) -> String {
        value.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
            ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

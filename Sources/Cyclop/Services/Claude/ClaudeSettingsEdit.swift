import Foundation

/// Cyclop's entry in Claude's settings file: text in, text out, or a refusal.
/// Everything that is not the entry comes out as it went in; see `JSONTree`.
enum ClaudeSettingsEdit {
    enum State: Equatable { case notConnected, connected, anotherCopy, unreadable }

    /// The text is not JSON, or `hooks` / `PermissionRequest` is not what it should be.
    struct Unreadable: Error, Equatable {}

    /// How long Claude Code keeps the hook (a day): `research.md` §4 found no cap.
    static let timeout = 86400

    /// The path quoted for the shell, then the argument that makes the executable a relay.
    static func command(forExecutable path: String) -> String {
        var quoted = ""
        for character in path {
            if "\\\"$`".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return "\"\(quoted)\" \(ClaudeWire.relayArgument)"
    }

    /// A missing file (`nil`) holds no entry.
    static func state(of text: String?, command: String) -> State {
        guard let root = try? parse(text), let ours = try? ourCommands(in: root) else { return .unreadable }
        if ours.isEmpty { return .notConnected }
        return ours.contains(command) ? .connected : .anotherCopy
    }

    /// The file with exactly one entry for `command`, in place of any older one of ours.
    static func connecting(_ text: String?, command: String) throws -> String {
        let root = try parse(text)
        let ours = try ourCommands(in: root)
        if let text, ours.contains(command) { return text }

        let entry = JSONTree.object([
            .init("type", .string("command")),
            .init("command", .string(command)),
            .init("timeout", .number(timeout)),
        ])
        let updated = try root.updating("hooks", create: .object([])) { hooks in
            try hooks.updating("PermissionRequest", create: .array([])) { groups in
                guard case .array(let list) = groups else { throw Unreadable() }
                var placed = false
                var result = removingOurs(from: list) { _ in
                    defer { placed = true }
                    return placed ? nil : entry
                }
                if !placed { result.append(.object([.init("hooks", .array([entry]))])) }
                return .array(result)
            }
        }
        return printed(updated, like: text)
    }

    /// The file without any entry of ours, and without the `PermissionRequest` and `hooks` the removal emptied.
    static func disconnecting(_ text: String?) throws -> String {
        let root = try parse(text)
        guard let text, try !ourCommands(in: root).isEmpty else { return text ?? "" }

        let updated = try root.updating("hooks", create: .object([])) { hooks in
            let rest = try hooks.updating("PermissionRequest", create: .array([])) { groups in
                guard let list = groups.items else { throw Unreadable() }
                let result = removingOurs(from: list) { _ in nil }
                return result.isEmpty ? nil : .array(result)
            }
            return rest.members?.isEmpty == true ? nil : rest
        }
        return printed(updated, like: text)
    }

    // MARK: - Tree

    private static func parse(_ text: String?) throws -> JSONTree {
        guard let text else { return .object([]) }
        guard let tree = JSONTree(parsing: text), tree.members != nil else { throw Unreadable() }
        return tree
    }

    /// The commands of our hooks, in file order; throws if `hooks` or `PermissionRequest` has the wrong type.
    private static func ourCommands(in root: JSONTree) throws -> [String] {
        guard let hooks = root["hooks"] else { return [] }
        guard hooks.members != nil else { throw Unreadable() }
        guard let groups = hooks["PermissionRequest"] else { return [] }
        guard let list = groups.items else { throw Unreadable() }
        return list.flatMap { $0["hooks"]?.items ?? [] }.compactMap { ours($0) }
    }

    /// The command of a hook that is ours: it ends with the relay argument.
    private static func ours(_ hook: JSONTree) -> String? {
        guard let command = hook["command"]?.text, command.hasSuffix(" " + ClaudeWire.relayArgument) else { return nil }
        return command
    }

    /// The groups without our hooks. The first of ours is swapped for what `replacement` returns
    /// (nil removes it); a group that held only ours and ends up empty goes too.
    private static func removingOurs(from groups: [JSONTree], replacement: (JSONTree) -> JSONTree?) -> [JSONTree] {
        groups.compactMap { group in
            guard let hooks = group["hooks"]?.items, hooks.contains(where: { ours($0) != nil }) else { return group }
            let kept = hooks.compactMap { ours($0) == nil ? $0 : replacement($0) }
            return kept.isEmpty ? nil : group.replacing("hooks", with: .array(kept))
        }
    }

    /// Pretty-printed, with the trailing newline the original had (a new file gets one).
    private static func printed(_ tree: JSONTree, like original: String?) -> String {
        tree.pretty + (original.map { $0.hasSuffix("\n") } ?? true ? "\n" : "")
    }
}

extension JSONTree {
    /// Changes the last member with that name, adds it (made by `create`) when there is none, or removes it when
    /// `change` returns nil. Throws `Unreadable` unless this is an object.
    fileprivate func updating(
        _ name: String, create: JSONTree, _ change: (JSONTree) throws -> JSONTree?
    ) throws -> JSONTree {
        guard case .object(var members) = self else { throw ClaudeSettingsEdit.Unreadable() }
        if let index = members.lastIndex(where: { $0.name == name }) {
            if let value = try change(members[index].value) {
                members[index].value = value
            } else {
                members.remove(at: index)
            }
        } else if let value = try change(create) {
            members.append(.init(name, value))
        }
        return .object(members)
    }

    fileprivate func replacing(_ name: String, with value: JSONTree) -> JSONTree {
        guard case .object(var members) = self, let index = members.lastIndex(where: { $0.name == name }) else { return self }
        members[index].value = value
        return .object(members)
    }
}

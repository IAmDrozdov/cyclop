import Darwin
import Foundation

/// Claude's settings file on disk: read it, and replace it safely.
struct ClaudeSettingsFile: Sendable {
    enum Failure: Error, Equatable {
        /// The file could not be read, or is not what the edit expects.
        case unreadable
        /// The file changed between the reading and the write, or could not be written.
        case notChanged
    }

    /// How many dated copies stay in the backups folder.
    static let keptCopies = 5

    let url: URL
    /// Where the dated copies go; the folder is made by `keepCopy`, owner-only.
    let backups: @Sendable () -> URL

    /// `~/.claude/settings.json`, or the file `CYCLOP_CLAUDE_SETTINGS` names (development).
    static let standard = ClaudeSettingsFile(
        url: ProcessInfo.processInfo.environment["CYCLOP_CLAUDE_SETTINGS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
        backups: { Support.file("claude-settings-backups") }
    )

    /// The text; nil when there is no file. Throws `unreadable` for a file that cannot be read as UTF-8.
    func read() throws -> String? {
        guard let data = try readData() else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.unreadable }
        return text
    }

    /// Applies `edit` to the file's text and replaces the file with the result: a copy first,
    /// then a check that nobody changed the file meanwhile, then an atomic replace.
    /// A symbolic link is followed, the mode is kept, a missing file (and its folder) is created.
    func change(_ edit: (String?) throws -> String) throws {
        let target = url.resolvingSymlinksInPath()
        let before = try readData(at: target)
        let text: String? = try before.map {
            guard let text = String(data: $0, encoding: .utf8) else { throw Failure.unreadable }
            return text
        }
        let result: String
        do { result = try edit(text) } catch { throw Failure.unreadable }
        guard result != text else { return }

        if let before { try keepCopy(of: before) }
        guard try readData(at: target) == before else { throw Failure.notChanged }
        try replace(target, with: Data(result.utf8))
    }

    // MARK: - Disk

    private func readData() throws -> Data? { try readData(at: url.resolvingSymlinksInPath()) }

    private func readData(at path: URL) throws -> Data? {
        do {
            return try Data(contentsOf: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw Failure.unreadable
        }
    }

    /// `settings-20261013-101530-123.json`, owner-only; older copies beyond the last five are removed.
    private func keepCopy(of data: Data) throws {
        let folder = backups()
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        // Two copies within a millisecond still get two names, in the order they were made.
        var moment = Date()
        var copy = folder.appendingPathComponent("settings-\(stamp.string(from: moment)).json")
        while fm.fileExists(atPath: copy.path) {
            moment.addTimeInterval(0.001)
            copy = folder.appendingPathComponent("settings-\(stamp.string(from: moment)).json")
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // A folder that was already there keeps its old mode above.
            guard chmod(folder.path, 0o700) == 0 else { throw Failure.notChanged }
            // Created owner-only, so a copy with a token in it is never readable by others.
            let fd = open(copy.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw Failure.notChanged }
            let written = ClaudeWire.writeAll(fd, data) && fchmod(fd, 0o600) == 0
            close(fd)
            guard written else {
                unlink(copy.path)
                throw Failure.notChanged
            }
        } catch {
            throw Failure.notChanged
        }
        let copies = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("settings-") && $0.hasSuffix(".json") }
            .sorted()
        for old in copies.dropLast(Self.keptCopies) { try? fm.removeItem(at: folder.appendingPathComponent(old)) }
    }

    /// A temporary file beside the target, then `rename`: the file is whole before and whole after.
    private func replace(_ target: URL, with data: Data) throws {
        let fm = FileManager.default
        let mode = ((try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber)
            .map { mode_t($0.uint16Value) } ?? 0o644
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw Failure.notChanged
        }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".cyclop-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw Failure.notChanged }
        var done = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        // The mode is set on the descriptor: the umask does not get a say.
        done = done && fchmod(fd, mode) == 0 && fsync(fd) == 0
        close(fd)
        guard done, rename(temporary.path, target.path) == 0 else {
            unlink(temporary.path)
            throw Failure.notChanged
        }
    }
}

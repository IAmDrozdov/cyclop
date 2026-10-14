import Darwin
import Foundation

/// What the kernel says about other processes. Needs no permission.
enum ProcessTable {
    /// Whether the process with this id is the one that wrote `procStart`
    /// (`ps`'s lstart format, in UTC: `Mon Oct 12 08:31:22 2026`), not a later one that got
    /// the same id. Without a readable start time, a live id is enough.
    static func isAlive(pid: Int, procStart: String?) -> Bool {
        guard let info = info(of: pid) else { return false }
        guard let procStart, let written = startFormatter.date(from: procStart.split(separator: " ").joined(separator: " "))
        else { return true }
        let started = Double(info.kp_proc.p_starttime.tv_sec)
        return abs(started - written.timeIntervalSince1970) <= 2
    }

    /// The app bundle that owns the process: the outermost `.app` on the path of
    /// the nearest ancestor that runs from one. An editor's extension host is a
    /// helper app inside the editor's own, hence the outermost.
    static func owningApp(of pid: Int) -> URL? {
        var current = parent(of: pid)
        var hops = 0
        while let candidate = current, candidate > 1, hops < 32 {
            if let path = executablePath(of: candidate), let range = path.range(of: ".app/") {
                return URL(fileURLWithPath: String(path[..<path.index(before: range.upperBound)]))
            }
            current = parent(of: candidate)
            hops += 1
        }
        return nil
    }

    /// The process's controlling terminal as `/dev/ttysNNN`; nil without one or for any other device name.
    static func tty(of pid: Int) -> String? {
        guard let device = info(of: pid)?.kp_eproc.e_tdev, device != -1,
            let name = devname(device, mode_t(S_IFCHR)).map({ String(cString: $0) }),
            name.wholeMatch(of: /ttys[0-9]{1,6}/) != nil
        else { return nil }
        return "/dev/" + name
    }

    /// The process's command line (`argv`, program name first); nil when the kernel does not give it.
    static func arguments(of pid: Int) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // argc, the executable's path, NUL padding, then argc strings; the environment follows.
        let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < size {
            var end = index
            while end < size, buffer[end] != 0 { end += 1 }
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments.count == count ? arguments : nil
    }

    private static func parent(of pid: Int) -> Int? {
        info(of: pid).map { Int($0.kp_eproc.e_ppid) }
    }

    static func executablePath(of pid: Int) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func info(of pid: Int) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == Int32(pid)
        else { return nil }
        return info
    }

    private static let startFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Claude Code writes the time in UTC, whatever the Mac's zone.
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()
}

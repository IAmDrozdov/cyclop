import Darwin
import Foundation

/// What the relay and the listener agree on. One connection carries one
/// request: a 4-byte big-endian length, then that many bytes. The reply is
/// whatever comes back until the listener closes.
enum ClaudeWire {
    /// The argument that makes the executable a relay instead of an app.
    static let relayArgument = "--claude-relay"
    static let maxRequest = 16 * 1024 * 1024

    /// In Cyclop's support folder. Built without creating the folder: the relay
    /// runs whether or not Cyclop ever has.
    static var defaultSocketPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cyclop/claude.sock").path
    }

    static func frame(_ request: Data) -> Data {
        var length = UInt32(request.count).bigEndian
        return Data(bytes: &length, count: 4) + request
    }

    /// Nil when the path does not fit in `sun_path` (104 bytes, the NUL included).
    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// A new stream socket that does not raise SIGPIPE and does not outlive an exec.
    static func makeSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                var wait = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                poll(&wait, 1, 1000)
            } else {
                return false
            }
        }
        return true
    }
}

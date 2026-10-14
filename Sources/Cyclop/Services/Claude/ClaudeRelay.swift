import Darwin
import Foundation

/// The hook's side of the wire: the executable started with `--claude-relay`.
/// Whatever happens it ends with exit 0 and, without an answer, no output, so
/// Claude asks as usual.
enum ClaudeRelay {
    /// Reads the request from `input`, passes it to the socket, prints what comes back.
    static func run(
        socketPath: String = ClaudeWire.defaultSocketPath,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) -> Int32 {
        guard let request = try? input.readToEnd(), !request.isEmpty, request.count <= ClaudeWire.maxRequest,
            var address = ClaudeWire.address(for: socketPath),
            let fd = ClaudeWire.makeSocket()
        else { return 0 }
        defer { close(fd) }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected, ClaudeWire.writeAll(fd, ClaudeWire.frame(request)) else { return 0 }

        // The sending side stays open: its end is how the listener learns the hook was killed.
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                reply.append(contentsOf: buffer[..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        if !reply.isEmpty { try? output.write(contentsOf: reply) }
        return 0
    }
}

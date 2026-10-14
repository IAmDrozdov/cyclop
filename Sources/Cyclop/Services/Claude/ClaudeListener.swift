import Darwin
import Foundation

/// One relay's connection, as the store sees it: answer it, close it, learn that it left.
final class ClaudeConnection: @unchecked Sendable {
    private enum Phase { case receiving, waiting, finished }

    private let lock = NSLock()
    private let fd: Int32
    private var phase = Phase.receiving
    private var received = Data()
    private var hungUp = false
    private var hangupHandler: (@Sendable () -> Void)?
    private var source: DispatchSourceRead?
    private let deliver: @Sendable (Data, ClaudeConnection) -> Void
    private let finished: @Sendable (ClaudeConnection) -> Void

    fileprivate init(
        fd: Int32, queue: DispatchQueue,
        deliver: @escaping @Sendable (Data, ClaudeConnection) -> Void,
        finished: @escaping @Sendable (ClaudeConnection) -> Void
    ) {
        self.fd = fd
        self.deliver = deliver
        self.finished = finished
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in readable() }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
    }

    fileprivate func start() {
        source?.resume()
    }

    /// Writes the answer and closes. Does nothing once the connection is over.
    func reply(_ data: Data) {
        lock.lock()
        guard phase == .waiting else { lock.unlock(); return }
        phase = .finished
        lock.unlock()
        _ = ClaudeWire.writeAll(fd, data)
        lock.lock()
        teardown()
        lock.unlock()
    }

    /// Closes without an answer, which ends the relay quietly.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard phase != .finished else { return }
        phase = .finished
        teardown()
    }

    /// Called once, on the main queue, if the relay goes away before it was answered; at once if it already has.
    func onHangup(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if hungUp {
            DispatchQueue.main.async(execute: handler)
        } else {
            hangupHandler = handler
        }
    }

    fileprivate func closeIfStillReceiving() {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .receiving else { return }
        phase = .finished
        teardown()
    }

    /// Lock held. The cancel handler closes the descriptor once no event is running.
    private func teardown() {
        source?.cancel()
        source = nil
        received = Data()
        hangupHandler = nil
        finished(self)
    }

    private func readable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &buffer, buffer.count)
        lock.lock()
        defer { lock.unlock() }
        guard phase != .finished else { return }
        if count > 0 {
            guard phase == .receiving else { return }
            received.append(contentsOf: buffer[..<count])
            guard received.count >= 4 else { return }
            let length = Int(received.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length > 0, length <= ClaudeWire.maxRequest else {
                phase = .finished
                teardown()
                return
            }
            guard received.count >= 4 + length else { return }
            let request = Data(received.dropFirst(4).prefix(length))
            received = Data()
            phase = .waiting
            deliver(request, self)
        } else if count < 0, errno == EINTR || errno == EAGAIN {
            return
        } else {
            // End of the stream or an error. The relay never closes its end by itself, so while
            // waiting this is the hook being killed.
            let handler = phase == .waiting ? hangupHandler : nil
            hungUp = phase == .waiting
            phase = .finished
            teardown()
            if let handler { DispatchQueue.main.async(execute: handler) }
        }
    }
}

/// The socket the relay connects to.
final class ClaudeListener: @unchecked Sendable {
    enum StartError: Error, Equatable {
        case pathTooLong
        /// Another process listens on the path.
        case inUse
        case failed(Int32)
    }

    /// A whole request and the means to answer it.
    typealias Handler = @MainActor @Sendable (Data, ClaudeConnection) -> Void

    /// How long a connection may take to deliver its request.
    private static let receiveTimeout: TimeInterval = 10

    private let path: String
    private let queue = DispatchQueue(label: "cyclop.claude.listener")
    private let lock = NSLock()
    private var accepting: DispatchSourceRead?
    private var connections: [ObjectIdentifier: ClaudeConnection] = [:]

    init(path: String = ClaudeWire.defaultSocketPath) {
        self.path = path
    }

    /// Owner-only, replacing a stale socket file but never a live one. `onRequest` runs on the main actor.
    func start(onRequest: @escaping Handler) throws {
        guard var address = ClaudeWire.address(for: path) else { throw StartError.pathTooLong }
        stop()
        if Self.someoneListens(at: address) { throw StartError.inUse }
        unlink(path)
        guard let fd = ClaudeWire.makeSocket() else { throw StartError.failed(errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
            let reason = errno
            close(fd)
            unlink(path)
            throw StartError.failed(reason)
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in
            while accept(from: fd, onRequest: onRequest) {}
        }
        source.setCancelHandler { Darwin.close(fd) }
        lock.lock()
        accepting = source
        lock.unlock()
        source.resume()
    }

    /// Whether a connect to the path is taken up (or would wait): the file is not stale then.
    private static func someoneListens(at address: sockaddr_un) -> Bool {
        guard let fd = ClaudeWire.makeSocket() else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = address
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 || errno == EAGAIN || errno == EINPROGRESS || errno == ETIMEDOUT
    }

    /// Closes the socket, removes its file and ends every waiting relay without an answer.
    func stop() {
        lock.lock()
        let source = accepting
        let open = Array(connections.values)
        accepting = nil
        connections = [:]
        lock.unlock()
        guard source != nil else { return }
        source?.cancel()
        unlink(path)
        open.forEach { $0.close() }
    }

    /// Takes one waiting connection off the queue. False when there is none.
    private func accept(from listening: Int32, onRequest: @escaping Handler) -> Bool {
        let fd = Darwin.accept(listening, nil, nil)
        guard fd >= 0 else { return false }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            close(fd)
            return true
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let connection = ClaudeConnection(
            fd: fd, queue: queue,
            deliver: { request, connection in
                DispatchQueue.main.async { MainActor.assumeIsolated { onRequest(request, connection) } }
            },
            finished: { [self] connection in
                lock.lock()
                connections[ObjectIdentifier(connection)] = nil
                lock.unlock()
            }
        )
        lock.lock()
        let running = accepting != nil
        if running { connections[ObjectIdentifier(connection)] = connection }
        lock.unlock()
        connection.start()
        if running {
            queue.asyncAfter(deadline: .now() + Self.receiveTimeout) { connection.closeIfStillReceiving() }
        } else {
            connection.close()
        }
        return true
    }
}

// MARK: - What the store sees

/// A relay's connection, as the store uses it; tests put a substitute in its place.
protocol ClaudeReplying: AnyObject, Sendable {
    func reply(_ data: Data)
    func close()
    func onHangup(_ handler: @escaping @Sendable () -> Void)
}

extension ClaudeConnection: ClaudeReplying {}

/// The socket, as the store uses it.
@MainActor
protocol ClaudeListening: AnyObject {
    func start(onRequest: @escaping @MainActor @Sendable (Data, any ClaudeReplying) -> Void) throws
    func stop()
}

/// The real socket in Cyclop's support folder.
@MainActor
final class SocketListening: ClaudeListening {
    private let listener = ClaudeListener()

    func start(onRequest: @escaping @MainActor @Sendable (Data, any ClaudeReplying) -> Void) throws {
        _ = Support.folder  // the socket file lives there, and bind does not make folders
        try listener.start { data, connection in onRequest(data, connection) }
    }

    func stop() { listener.stop() }
}

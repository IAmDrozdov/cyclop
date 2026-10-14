import Darwin
import Foundation
import Testing
@testable import Cyclop

/// Тесты на сокет Claude и ретранслятор: настоящий сокет во временной папке и
/// настоящий исполняемый файл Cyclop, запущенный дочерним процессом с
/// `--claude-relay`. Ждут событий с щедрым сроком и никогда не спят вслепую;
/// ребёнок убивается по сроку. Путь сокета короткий — предел `sun_path` 104 байта.
@MainActor
struct ClaudeListenerTests {

    private nonisolated static let deadline: TimeInterval = 30

    // MARK: - Обвязка

    /// Очередь событий, которые приходят на главную очередь: ждёт одно и сдаётся по сроку.
    @MainActor
    private final class Inbox<Value: Sendable> {
        private var values: [Value] = []
        private var waiter: (id: Int, continuation: CheckedContinuation<Value?, Never>)?
        private var serial = 0

        func send(_ value: Value) {
            if let waiter {
                self.waiter = nil
                waiter.continuation.resume(returning: value)
            } else {
                values.append(value)
            }
        }

        func next(within seconds: TimeInterval = ClaudeListenerTests.deadline) async -> Value? {
            if !values.isEmpty { return values.removeFirst() }
            serial += 1
            let id = serial
            return await withCheckedContinuation { continuation in
                waiter = (id, continuation)
                Task { [self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    if let current = waiter, current.id == id {
                        waiter = nil
                        current.continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    /// Ретранслятор — настоящий процесс. Вывод читается по мере поступления: ответ
    /// длиннее буфера трубы иначе повесил бы ребёнка.
    private final class Relay: @unchecked Sendable {
        let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let lock = NSLock()
        private var collected = Data()

        init(socket: String, arguments: [String] = []) throws {
            process.executableURL = try ClaudeListenerTests.executable()
            process.arguments = [ClaudeWire.relayArgument, socket] + arguments
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                lock.withLock { collected.append(chunk) }
            }
        }

        func start(sending request: Data) throws {
            try process.run()
            let sink = input.fileHandleForWriting
            DispatchQueue.global().async {
                try? sink.write(contentsOf: request)
                try? sink.close()
            }
        }

        func kill() { Darwin.kill(process.processIdentifier, SIGKILL) }

        /// Код выхода и всё, что ретранслятор напечатал. По сроку ребёнок убивается, и код это покажет.
        func finish(within seconds: TimeInterval = ClaudeListenerTests.deadline) async -> (status: Int32, output: Data) {
            let guardian = DispatchWorkItem { [self] in kill() }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: guardian)
            await Task.detached { [process] in process.waitUntilExit() }.value
            guardian.cancel()
            output.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            let all = lock.withLock {
                collected.append(rest)
                return collected
            }
            return (process.terminationStatus, all)
        }
    }

    private final class Anchor {}

    /// Собранный рядом с пакетом тестов исполняемый файл Cyclop.
    private nonisolated static func executable() throws -> URL {
        let tests = Bundle(for: Anchor.self).bundleURL
        let url = tests.deletingLastPathComponent().appendingPathComponent("Cyclop")
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "нет \(url.path)")
        return url
    }

    /// Короткая папка: `/tmp/cy-XXXXXX/`.
    private static func shortFolder() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/cy-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Harness {
        let folder: URL
        let socket: String
        let listener: ClaudeListener
        let requests: Inbox<(Data, ClaudeConnection)>
        let hangups: Inbox<Void>
    }

    private static func listening() throws -> Harness {
        let folder = try shortFolder()
        let socket = folder.appendingPathComponent("s").path
        let listener = ClaudeListener(path: socket)
        let requests = Inbox<(Data, ClaudeConnection)>()
        let hangups = Inbox<Void>()
        try listener.start { data, connection in
            connection.onHangup { MainActor.assumeIsolated { hangups.send(()) } }
            requests.send((data, connection))
        }
        return Harness(folder: folder, socket: socket, listener: listener, requests: requests, hangups: hangups)
    }

    private static func request(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Запрос и ответ

    @Test func aRequestReachesTheHandlerWholeAndTheReplyComesOutOfTheRelay() async throws {
        let rig = try Self.listening()
        defer { rig.listener.stop() }
        let relay = try Relay(socket: rig.socket)
        try relay.start(sending: Self.request(#"{"tool_name":"Bash"}"#))

        let (data, connection) = try #require(await rig.requests.next())
        #expect(String(decoding: data, as: UTF8.self) == #"{"tool_name":"Bash"}"#)
        connection.reply(Self.request(#"{"behavior":"allow"}"#))

        let result = await relay.finish()
        #expect(result.status == 0)
        #expect(String(decoding: result.output, as: UTF8.self) == #"{"behavior":"allow"}"#)
    }

    @Test func aHandlerThatClosesWithoutAnAnswerGivesNoOutputAndExitZero() async throws {
        let rig = try Self.listening()
        defer { rig.listener.stop() }
        let relay = try Relay(socket: rig.socket)
        try relay.start(sending: Self.request("x"))

        let (_, connection) = try #require(await rig.requests.next())
        connection.close()

        let result = await relay.finish()
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test func aLongRequestWithCyrillicArrivesWhole() async throws {
        let rig = try Self.listening()
        defer { rig.listener.stop() }
        let text = String(repeating: "Привет, мир! ", count: 60_000 / 13)
        #expect(text.count >= 59_000)
        let relay = try Relay(socket: rig.socket)
        try relay.start(sending: Self.request(text))

        let (data, connection) = try #require(await rig.requests.next())
        #expect(String(decoding: data, as: UTF8.self) == text)
        connection.reply(data)

        let result = await relay.finish()
        #expect(result.status == 0)
        #expect(result.output == data)
    }

    // MARK: - Когда ответа не будет

    @Test func withNoSocketTheRelayEndsAtOnceWithNothing() async throws {
        let folder = try Self.shortFolder()
        let relay = try Relay(socket: folder.appendingPathComponent("none").path)
        try relay.start(sending: Self.request("x"))
        let result = await relay.finish()
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test func aStaleSocketFileIsTheSameAsNoSocket() async throws {
        let folder = try Self.shortFolder()
        let path = folder.appendingPathComponent("stale").path
        // Файл-сокет, на котором никто не слушает: bind без listen и закрытие.
        var address = try #require(ClaudeWire.address(for: path))
        let fd = try #require(ClaudeWire.makeSocket())
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        try #require(bound == 0)
        try #require(FileManager.default.fileExists(atPath: path))

        let relay = try Relay(socket: path)
        try relay.start(sending: Self.request("x"))
        let result = await relay.finish()
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test func aRequestOverSixteenMegabytesIsNotSent() async throws {
        let rig = try Self.listening()
        defer { rig.listener.stop() }
        let relay = try Relay(socket: rig.socket)
        try relay.start(sending: Data(repeating: 0x61, count: ClaudeWire.maxRequest + 1))
        let result = await relay.finish()
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test func aFrameDeclaringMoreThanSixteenMegabytesIsClosedWithoutAnAnswer() throws {
        let rig = try Self.listening()
        defer { rig.listener.stop() }
        var address = try #require(ClaudeWire.address(for: rig.socket))
        let fd = try #require(ClaudeWire.makeSocket())
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(connected == 0)
        var length = UInt32(ClaudeWire.maxRequest + 1).bigEndian
        try #require(write(fd, &length, 4) == 4)

        // Слушатель закрывает соединение: чтение возвращает конец потока.
        var byte: UInt8 = 0
        #expect(read(fd, &byte, 1) == 0)
    }

    // MARK: - Обрыв и остановка

    @Test func aRelayKilledWhileItWaitsIsReportedAsAHangup() async throws {
        let rig = try Self.listening()
        defer { rig.listener.stop() }
        let relay = try Relay(socket: rig.socket)
        try relay.start(sending: Self.request("x"))
        _ = try #require(await rig.requests.next())

        relay.kill()
        #expect(await rig.hangups.next() != nil)
        _ = await relay.finish()
    }

    @Test func stoppingTheListenerEndsEveryWaitingRelayWithNothing() async throws {
        let rig = try Self.listening()
        let first = try Relay(socket: rig.socket)
        let second = try Relay(socket: rig.socket)
        try first.start(sending: Self.request("1"))
        try second.start(sending: Self.request("2"))
        _ = try #require(await rig.requests.next())
        _ = try #require(await rig.requests.next())

        rig.listener.stop()
        for relay in [first, second] {
            let result = await relay.finish()
            #expect(result.status == 0)
            #expect(result.output.isEmpty)
        }
    }

    // MARK: - Файл сокета

    @Test func theSocketFileIsOwnerOnlyAndGoneAfterStop() throws {
        let rig = try Self.listening()
        let attributes = try FileManager.default.attributesOfItem(atPath: rig.socket)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        rig.listener.stop()
        #expect(!FileManager.default.fileExists(atPath: rig.socket))
    }

    @Test func aStaleSocketFileIsReplacedAtStart() throws {
        let folder = try Self.shortFolder()
        let path = folder.appendingPathComponent("s").path
        try Data("stale".utf8).write(to: folder.appendingPathComponent("s"))
        let listener = ClaudeListener(path: path)
        try listener.start { _, connection in connection.close() }
        defer { listener.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.type] as? FileAttributeType) == .typeSocket)
    }

    @Test func aSocketAnotherProcessListensOnIsNotTakenOver() async throws {
        let rig = try Self.listening()
        defer { rig.listener.stop() }
        let second = ClaudeListener(path: rig.socket)

        #expect(throws: ClaudeListener.StartError.inUse) {
            try second.start { _, connection in connection.close() }
        }

        // Файл на месте, и первый слушатель по-прежнему получает запросы.
        #expect(FileManager.default.fileExists(atPath: rig.socket))
        let relay = try Relay(socket: rig.socket)
        try relay.start(sending: Self.request("x"))
        let (data, connection) = try #require(await rig.requests.next())
        #expect(String(decoding: data, as: UTF8.self) == "x")
        connection.reply(Self.request("ok"))
        let result = await relay.finish()
        #expect(String(decoding: result.output, as: UTF8.self) == "ok")
    }

    @Test func aSocketFileNobodyListensOnIsReplacedAtStart() throws {
        let folder = try Self.shortFolder()
        let path = folder.appendingPathComponent("s").path
        // Файл-сокет после умершего процесса: bind без listen и закрытие.
        var address = try #require(ClaudeWire.address(for: path))
        let fd = try #require(ClaudeWire.makeSocket())
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        try #require(bound == 0)

        let listener = ClaudeListener(path: path)
        try listener.start { _, connection in connection.close() }
        defer { listener.stop() }

        // Новый слушатель действительно принимает соединения.
        var probe = try #require(ClaudeWire.address(for: path))
        let client = try #require(ClaudeWire.makeSocket())
        defer { close(client) }
        let connected = withUnsafePointer(to: &probe) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)
    }

    @Test func aPathOverTheLimitIsReportedNotACrash() throws {
        let listener = ClaudeListener(path: "/tmp/" + String(repeating: "a", count: 120))
        #expect(throws: ClaudeListener.StartError.pathTooLong) {
            try listener.start { _, connection in connection.close() }
        }
    }
}

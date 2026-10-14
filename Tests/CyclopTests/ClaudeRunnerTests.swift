import Foundation
import Testing
@testable import Cyclop

/// Настоящий запуск процесса через `SystemClaudeRunner`, но не `claude`: короткие скрипты `sh` во временной папке.
struct ClaudeRunnerTests {

    private static func script(_ body: String) throws -> (folder: URL, script: URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cyclop-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("step.sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (folder, script)
    }

    private static func run(_ body: String, timeout: TimeInterval = 10) async throws -> ClaudeRun {
        let (folder, script) = try script(body)
        return await SystemClaudeRunner(grace: 0.3).run(
            executable: script, arguments: [], folder: folder, environment: ["PATH": "/usr/bin:/bin"], timeout: timeout)
    }

    @Test func theStandardErrorOfAFailedStepIsKeptToTheEnd() async throws {
        let run = try await Self.run("echo first >&2; echo 'Error: not logged in' >&2; exit 3")

        #expect(run.status == 3 && !run.timedOut)
        #expect(ClaudeHandoff.reason(ofStandardError: run.standardError) == "Error: not logged in")
    }

    @Test func aStepThatIgnoresTermIsKilledAfterTheGrace() async throws {
        let clock = ContinuousClock()
        let started = clock.now

        let run = try await Self.run("trap '' TERM; while true; do sleep 1; done", timeout: 0.3)

        #expect(run.timedOut)
        #expect(clock.now - started < .seconds(5))
        #expect(run.status != 0)
    }
}

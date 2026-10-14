import Foundation
import Testing
@testable import Cyclop

/// Тесты подключения к Claude в `ClaudeStore`: запись и снятие записи в файле настроек
/// и сокет, который слушает ровно пока запись есть. Файл настроек и папка копий — временные.
@MainActor
struct ClaudeConnectionTests {

    private typealias Rig = ClaudeStoreTests.Rig

    private static let original = """
        {
          "model": "opus",
          "permissions": {
            "allow": [
              "Bash(ls:*)"
            ]
          }
        }

        """

    private func entries(_ text: String?) -> Int {
        guard let text, let tree = JSONTree(parsing: text) else { return 0 }
        return (tree["hooks"]?["PermissionRequest"]?.items ?? []).count
    }

    private func copies(_ rig: Rig) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rig.backups.path)) ?? []
        return names.sorted().map { rig.backups.appendingPathComponent($0) }
    }

    // MARK: - Подключить и отключить

    @Test func connectWritesTheEntryAfterKeepingACopyAndDisconnectBringsTheFileBack() throws {
        let rig = try Rig()
        try rig.writeSettings(Self.original)
        rig.store.refreshConnection()
        #expect(rig.store.connection == .notConnected)

        rig.store.connect()

        #expect(rig.store.connection == .connected)
        #expect(entries(rig.settingsText()) == 1)
        #expect(try String(contentsOf: try #require(copies(rig).first), encoding: .utf8) == Self.original)

        rig.store.disconnect()

        #expect(rig.store.connection == .notConnected)
        #expect(rig.settingsText() == Self.original)
        #expect(copies(rig).count == 2)
    }

    @Test func aMissingFileIsCreatedWithTheEntryAlone() throws {
        let rig = try Rig()

        rig.store.connect()

        #expect(rig.store.connection == .connected)
        #expect(rig.settingsText() == (try ClaudeSettingsEdit.connecting(nil, command: Rig.command)))
        #expect(copies(rig).isEmpty)
    }

    @Test func aFileThatDoesNotParseIsLeftUntouchedAndTheFailureIsShown() throws {
        let rig = try Rig()
        try rig.writeSettings("{ \"model\": \"opus\",, }")

        rig.store.connect()

        #expect(rig.settingsText() == "{ \"model\": \"opus\",, }")
        #expect(rig.store.connection == .unreadable)
        #expect(rig.store.connectionFailure == .unreadable)
        #expect(copies(rig).isEmpty)
    }

    @Test func aSymbolicLinkStaysALinkAndItsTargetChanges() throws {
        let rig = try Rig()
        let real = rig.settingsFolder.appendingPathComponent("dotfiles/claude.json")
        try FileManager.default.createDirectory(
            at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.original.utf8).write(to: real)
        try FileManager.default.createDirectory(
            at: rig.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: rig.settingsURL, withDestinationURL: real)

        rig.store.connect()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rig.settingsURL.path) == real.path)
        #expect(entries(try String(contentsOf: real, encoding: .utf8)) == 1)
        #expect(rig.store.connection == .connected)
    }

    @Test func theFileKeepsItsMode() throws {
        let rig = try Rig()
        try rig.writeSettings(Self.original)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: rig.settingsURL.path)

        rig.store.connect()

        let mode = try FileManager.default.attributesOfItem(atPath: rig.settingsURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o640)
    }

    @Test func aFileChangedBetweenTheReadingAndTheWriteIsNotWritten() throws {
        let rig = try Rig()
        try rig.writeSettings(Self.original)
        let file = ClaudeSettingsFile(url: rig.settingsURL, backups: { rig.backups })

        #expect(throws: ClaudeSettingsFile.Failure.notChanged) {
            try file.change { text in
                // Пока правка считается, кто-то другой пишет в файл.
                try Data("{\"other\": 1}".utf8).write(to: rig.settingsURL)
                return try ClaudeSettingsEdit.connecting(text, command: Rig.command)
            }
        }
        #expect(rig.settingsText() == "{\"other\": 1}")
    }

    @Test func copiesAreOwnerOnlyAndTheLastFiveStay() throws {
        let rig = try Rig()
        try rig.writeSettings(Self.original)
        // Папка копий уже есть и открыта всем (так её делал Support.directory): её закрывают.
        try FileManager.default.createDirectory(
            at: rig.backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        for _ in 0..<4 {
            rig.store.connect()
            rig.store.disconnect()
        }

        let kept = copies(rig)
        #expect(kept.count == ClaudeSettingsFile.keptCopies)
        for url in kept {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        let folderMode = try FileManager.default.attributesOfItem(atPath: rig.backups.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
    }

    // MARK: - Три состояния

    @Test func anEntryNamingAnotherPathReadsAsAnotherCopyAndConnectLeavesOne() throws {
        let rig = try Rig()
        let other = ClaudeSettingsEdit.command(forExecutable: "/Old/Cyclop.app/Contents/MacOS/Cyclop")
        try rig.writeSettings(try ClaudeSettingsEdit.connecting(Self.original, command: other))
        rig.store.refreshConnection()
        #expect(rig.store.connection == .anotherCopy)

        rig.store.connect()

        #expect(rig.store.connection == .connected)
        #expect(entries(rig.settingsText()) == 1)
        #expect(rig.settingsText()?.contains("/Old/Cyclop") == false)
    }

    @Test func nothingIsWrittenWithoutAPress() throws {
        let rig = try Rig()
        try rig.writeSettings(Self.original)

        rig.store.beginBackground()
        rig.store.refreshConnection()
        rig.store.endBackground()

        #expect(rig.settingsText() == Self.original)
        #expect(copies(rig).isEmpty)
    }

    @Test func theStateFollowsAFileEditedFromOutside() throws {
        let rig = try Rig()
        try rig.writeSettings(Self.original)
        rig.store.refreshConnection()
        try rig.writeSettings(try ClaudeSettingsEdit.connecting(Self.original, command: Rig.command))

        rig.store.refreshConnection()

        #expect(rig.store.connection == .connected)
    }

    // MARK: - Слушать ровно пока запись есть и вкладка на рейке

    @Test func theSocketIsOpenExactlyWhileTheTabIsOnARailAndTheEntryIsThere() throws {
        let rig = try Rig()
        try rig.writeSettings(try ClaudeSettingsEdit.connecting(Self.original, command: Rig.command))

        #expect(rig.listener.isListening == false)

        rig.store.beginBackground()
        #expect(rig.listener.isListening)

        rig.store.endBackground()
        #expect(rig.listener.isListening == false)
    }

    @Test func withoutTheEntryTheSocketIsNeverOpened() throws {
        let rig = try Rig()
        try rig.writeSettings(Self.original)

        rig.store.beginBackground()

        #expect(rig.listener.starts == 0)
        #expect(rig.listener.isListening == false)
    }

    @Test func connectAndDisconnectOpenAndCloseTheSocketWhileTheTabIsOnARail() throws {
        let rig = try Rig()
        try rig.writeSettings(Self.original)
        rig.store.beginBackground()

        rig.store.connect()
        #expect(rig.listener.isListening)

        rig.store.disconnect()
        #expect(rig.listener.isListening == false)
    }

    @Test func connectWithTheTabHiddenOpensNoSocket() throws {
        let rig = try Rig()
        try rig.writeSettings(Self.original)

        rig.store.connect()

        #expect(rig.store.connection == .connected)
        #expect(rig.listener.starts == 0)
    }

    @Test func anotherCopysEntryDoesNotOpenTheSocket() throws {
        let rig = try Rig()
        let other = ClaudeSettingsEdit.command(forExecutable: "/Old/Cyclop")
        try rig.writeSettings(try ClaudeSettingsEdit.connecting(Self.original, command: other))

        rig.store.beginBackground()

        #expect(rig.listener.starts == 0)
    }

    @Test func aSocketAnotherCopyListensOnIsReportedLikeAnyOtherFailureAndRetriedOnTheNextReading() throws {
        let rig = try Rig()
        try rig.writeSettings(try ClaudeSettingsEdit.connecting(Self.original, command: Rig.command))
        rig.listener.failure = .inUse

        rig.store.beginBackground()
        #expect(rig.store.listenFailed)
        #expect(rig.listener.isListening == false)

        // Другая копия закрылась: следующее чтение (по таймеру) открывает сокет.
        rig.listener.failure = nil
        rig.store.refreshConnection()
        #expect(rig.listener.isListening)
        #expect(rig.store.listenFailed == false)
    }

    // MARK: - Файл настроек, не прочитавшийся с первого раза

    @Test func oneUnreadableReadingKeepsTheSocketAndTheRequestsAndTwoInARowDoNot() throws {
        let rig = try Rig()
        let connected = try ClaudeSettingsEdit.connecting(Self.original, command: Rig.command)
        try rig.writeSettings(connected)
        try rig.write(7, status: "waiting")
        rig.store.beginBackground()
        let relay = rig.listener.arrive(
            #"{"session_id":"session-7","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        #expect(rig.store.requests.count == 1)

        // Файл пишется на лету: первое чтение ничего не меняет.
        try rig.writeSettings("{ \"hooks\": ")
        rig.store.refreshConnection()
        #expect(rig.store.connection == .connected)
        #expect(rig.listener.isListening)
        #expect(rig.store.requests.count == 1)
        #expect(!relay.isClosed)

        // Прочёлся: счёт заново.
        try rig.writeSettings(connected)
        rig.store.refreshConnection()
        try rig.writeSettings("{ \"hooks\": ")
        rig.store.refreshConnection()
        #expect(rig.listener.isListening)
        #expect(!relay.isClosed)

        // Второе подряд: запись правда сломана.
        rig.store.refreshConnection()
        #expect(rig.store.connection == .unreadable)
        #expect(rig.listener.isListening == false)
        #expect(rig.store.requests.isEmpty)
        #expect(relay.isClosed && relay.replies.isEmpty)
    }

    @Test func aSocketThatCannotBeOpenedIsReportedAndTheTabStaysAList() throws {
        let rig = try Rig()
        try rig.writeSettings(try ClaudeSettingsEdit.connecting(Self.original, command: Rig.command))
        rig.listener.failure = .pathTooLong

        rig.store.beginBackground()

        #expect(rig.store.listenFailed)
        #expect(rig.listener.isListening == false)
    }
}

import Foundation
import Testing
@testable import Cyclop

/// Тесты правки файла настроек Claude как чистой функции: текст в текст или отказ.
/// Файлов здесь нет: что делает запись на диск, проверяет `ClaudeStoreTests`.
struct ClaudeSettingsEditTests {

    private static let command = ClaudeSettingsEdit.command(forExecutable: "/Applications/Cyclop.app/Contents/MacOS/Cyclop")

    /// Запись целиком, как её печатает правка (отступ в два пробела).
    private static func entry(_ command: String = command, level: Int = 0) -> String {
        let lines = [
            "\"PermissionRequest\": [",
            "  {",
            "    \"hooks\": [",
            "      {",
            "        \"type\": \"command\",",
            "        \"command\": \(JSONTree.quote(command)),",
            "        \"timeout\": 86400",
            "      }",
            "    ]",
            "  }",
            "]",
        ]
        return lines.map { String(repeating: "  ", count: level) + $0 }.joined(separator: "\n")
    }

    /// Файл, какой пишет сам Claude Code: два пробела, чужие хуки и права, кириллица и экраны.
    private static let busy = """
        {
          "permissions": {
            "allow": [
              "Bash(ls:*)",
              "Read(//Users/sato/Заметки/**)"
            ],
            "defaultMode": "plan"
          },
          "env": {
            "RATIO": 1.50e3,
            "PATH_HINT": "a\\/b \\u00e9 \\"q\\" \\\\ \\n",
            "ПЕРЕМЕННАЯ": "значение"
          },
          "hooks": {
            "Notification": [
              {
                "matcher": "",
                "hooks": [
                  {
                    "type": "command",
                    "command": "say готово"
                  }
                ]
              }
            ],
            "PermissionRequest": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "python3 /Users/sato/hooks/other.py",
                    "timeout": 5
                  }
                ]
              }
            ]
          },
          "model": "opus",
          "includeCoAuthoredBy": false,
          "cleanupPeriodDays": 30
        }

        """

    private static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    // MARK: - Подключение

    @Test func aMissingFileIsCreatedWithTheEntryAlone() throws {
        let text = try ClaudeSettingsEdit.connecting(nil, command: Self.command)

        #expect(text == "{\n  \"hooks\": {\n" + Self.entry(level: 2) + "\n  }\n}\n")
    }

    @Test func anEmptyObjectGetsHooksAndTheEntry() throws {
        let text = try ClaudeSettingsEdit.connecting("{}", command: Self.command)

        #expect(text == "{\n  \"hooks\": {\n" + Self.entry(level: 2) + "\n  }\n}")
    }

    @Test func aFileWithoutHooksKeepsItsKeysAndGainsHooksLast() throws {
        let original = "{\n  \"model\": \"opus\",\n  \"n\": 1\n}\n"
        let text = try ClaudeSettingsEdit.connecting(original, command: Self.command)

        #expect(text == "{\n  \"model\": \"opus\",\n  \"n\": 1,\n  \"hooks\": {\n" + Self.entry(level: 2) + "\n  }\n}\n")
    }

    @Test func hooksWithoutPermissionRequestGainsItAfterTheOthers() throws {
        let original = "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n"
        let text = try ClaudeSettingsEdit.connecting(original, command: Self.command)

        #expect(text == "{\n  \"hooks\": {\n    \"Stop\": [],\n" + Self.entry(level: 2) + "\n  }\n}\n")
    }

    @Test func otherPeoplesGroupsKeepTheirPlaceAndOursComesAfter() throws {
        let text = try ClaudeSettingsEdit.connecting(Self.busy, command: Self.command)
        let tree = try #require(JSONTree(parsing: text))
        let groups = try #require(tree["hooks"]?["PermissionRequest"]?.items)

        #expect(groups.count == 2)
        #expect(groups[0]["matcher"]?.text == "Bash")
        #expect(groups[1]["hooks"]?.items?.first?["command"]?.text == Self.command)
        #expect(groups[1]["matcher"] == nil)
    }

    @Test func theEntryIsOneCommandHookWithADayTimeout() throws {
        let text = try ClaudeSettingsEdit.connecting("{}", command: Self.command)
        let tree = try #require(JSONTree(parsing: text))
        let hooks = try #require(tree["hooks"]?["PermissionRequest"]?.items?.first?["hooks"]?.items)

        #expect(hooks.count == 1)
        #expect(hooks[0]["type"]?.text == "command")
        #expect(hooks[0]["command"]?.text == Self.command)
        #expect(hooks[0]["timeout"] == .scalar("86400"))
    }

    @Test func aCommandQuotesAPathWithSpacesAndShellCharacters() {
        #expect(
            ClaudeSettingsEdit.command(forExecutable: "/Users/a b/Cyclop \"x\" $y.app/Cyclop")
                == "\"/Users/a b/Cyclop \\\"x\\\" \\$y.app/Cyclop\" --claude-relay")
    }

    @Test func connectingTwiceLeavesOneEntryAndTheSameText() throws {
        let once = try ClaudeSettingsEdit.connecting(Self.busy, command: Self.command)
        let twice = try ClaudeSettingsEdit.connecting(once, command: Self.command)

        #expect(twice == once)
    }

    @Test func connectingWithANewPathReplacesTheOldEntryInPlace() throws {
        let old = ClaudeSettingsEdit.command(forExecutable: "/Old/Cyclop.app/Contents/MacOS/Cyclop")
        let first = try ClaudeSettingsEdit.connecting(Self.busy, command: old)
        let second = try ClaudeSettingsEdit.connecting(first, command: Self.command)
        let groups = try #require(JSONTree(parsing: second)?["hooks"]?["PermissionRequest"]?.items)

        #expect(groups.count == 2)
        #expect(second.contains("Old/Cyclop") == false)
        #expect(groups[1]["hooks"]?.items?.first?["command"]?.text == Self.command)
        // Результат тот же, как если бы подключали сразу с новым путём.
        #expect(second == (try ClaudeSettingsEdit.connecting(Self.busy, command: Self.command)))
    }

    @Test func aDuplicatedEntryCollapsesToOneOnConnect() throws {
        let other = ClaudeSettingsEdit.command(forExecutable: "/Old/Cyclop")
        let double = """
            {"hooks": {"PermissionRequest": [
              {"hooks": [{"type": "command", "command": \(JSONTree.quote(other))}]},
              {"hooks": [{"type": "command", "command": \(JSONTree.quote(other))}]}
            ]}}
            """
        let text = try ClaudeSettingsEdit.connecting(double, command: Self.command)
        let groups = try #require(JSONTree(parsing: text)?["hooks"]?["PermissionRequest"]?.items)

        #expect(groups.count == 1)
        #expect(groups[0]["hooks"]?.items?.count == 1)
    }

    // MARK: - Отключение

    @Test func disconnectingTakesOnlyOurGroupAndLeavesTheRestAsItWas() throws {
        let connected = try ClaudeSettingsEdit.connecting(Self.busy, command: Self.command)
        let text = try ClaudeSettingsEdit.disconnecting(connected)

        #expect(text == Self.busy)
    }

    @Test func disconnectingFromAnEmptyFileRemovesTheKeysItEmptied() throws {
        let connected = try ClaudeSettingsEdit.connecting("{}", command: Self.command)

        #expect(try ClaudeSettingsEdit.disconnecting(connected) == "{}")
    }

    @Test func disconnectingKeepsHooksThatHoldOtherEvents() throws {
        let original = "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n"
        let connected = try ClaudeSettingsEdit.connecting(original, command: Self.command)

        #expect(try ClaudeSettingsEdit.disconnecting(connected) == original)
    }

    @Test func disconnectingFromAFileWithoutTheEntryReturnsTheTextUntouched() throws {
        // Даже не отформатированный по-нашему: ничего не меняется, значит и не переписывается.
        let original = "{ \"hooks\":{\"Stop\":[ ]},   \"a\" : 1 }"

        #expect(try ClaudeSettingsEdit.disconnecting(original) == original)
        #expect(try ClaudeSettingsEdit.disconnecting(Self.busy) == Self.busy)
    }

    @Test func disconnectingRemovesOnlyOurHookFromAGroupSharedWithOthers() throws {
        let shared = """
            {"hooks": {"PermissionRequest": [{"hooks": [
              {"type": "command", "command": "other"},
              {"type": "command", "command": \(JSONTree.quote(Self.command))}
            ]}]}}
            """
        let text = try ClaudeSettingsEdit.disconnecting(shared)
        let hooks = try #require(JSONTree(parsing: text)?["hooks"]?["PermissionRequest"]?.items?.first?["hooks"]?.items)

        #expect(hooks.count == 1)
        #expect(hooks[0]["command"]?.text == "other")
    }

    @Test func aMissingFileDisconnectsToNothing() throws {
        #expect(try ClaudeSettingsEdit.disconnecting(nil) == "")
    }

    // MARK: - Всё остальное остаётся как было

    @Test func everyOtherLineComesOutExactlyAsItWentIn() throws {
        let text = try ClaudeSettingsEdit.connecting(Self.busy, command: Self.command)
        let before = Self.lines(Self.busy)
        let after = Self.lines(text)

        // Строки файла идут в том же порядке; меняется только запятая после чужой группы
        // и прибавляются девять строк нашей группы.
        var next = after.startIndex
        for line in before {
            let found = try #require(
                after[next...].firstIndex(where: { $0 == line || $0 == line + "," }), "пропала строка: \(line)")
            next = after.index(after: found)
        }
        #expect(after.count - before.count == 9)
        #expect(text.contains("1.50e3"))
        #expect(text.contains("\"PATH_HINT\": \"a\\/b \\u00e9 \\\"q\\\" \\\\ \\n\""))
        #expect(text.contains("\"ПЕРЕМЕННАЯ\": \"значение\""))
        #expect(text.contains("Read(//Users/sato/Заметки/**)"))
    }

    @Test func aFileWithNoTrailingNewlineKeepsThatAndOneWithItKeepsIt() throws {
        let bare = try ClaudeSettingsEdit.connecting("{}", command: Self.command)
        let ended = try ClaudeSettingsEdit.connecting("{}\n", command: Self.command)

        #expect(bare.hasSuffix("}") && !bare.hasSuffix("\n"))
        #expect(ended.hasSuffix("}\n"))
    }

    @Test func duplicateKeysOfOtherPeopleSurvive() throws {
        let original = "{\n  \"a\": 1,\n  \"a\": 2\n}\n"
        let text = try ClaudeSettingsEdit.connecting(original, command: Self.command)

        #expect(text.hasPrefix("{\n  \"a\": 1,\n  \"a\": 2,\n  \"hooks\""))
    }

    // MARK: - Состояние

    @Test func theStateIsReadFromTheFile() throws {
        let other = ClaudeSettingsEdit.command(forExecutable: "/Old/Cyclop")

        #expect(ClaudeSettingsEdit.state(of: nil, command: Self.command) == .notConnected)
        #expect(ClaudeSettingsEdit.state(of: Self.busy, command: Self.command) == .notConnected)
        #expect(
            ClaudeSettingsEdit.state(
                of: try ClaudeSettingsEdit.connecting(Self.busy, command: Self.command), command: Self.command)
                == .connected)
        #expect(
            ClaudeSettingsEdit.state(
                of: try ClaudeSettingsEdit.connecting(Self.busy, command: other), command: Self.command)
                == .anotherCopy)
        #expect(ClaudeSettingsEdit.state(of: "{", command: Self.command) == .unreadable)
    }

    // MARK: - Отказы

    @Test(arguments: [
        "", "   ", "{", "{\"a\": }", "[1, 2]", "\"text\"", "42", "null",
        "{\"a\": 1,}", "{\"a\": 1} {}", "// c\n{}", "{'a': 1}", "{\"a\": 01}", "{\"a\": \"\u{1}\"}",
        "{\"hooks\": []}", "{\"hooks\": \"x\"}", "{\"hooks\": null}",
        "{\"hooks\": {\"PermissionRequest\": {}}}", "{\"hooks\": {\"PermissionRequest\": \"x\"}}",
    ])
    func textThatIsNotWhatWeExpectIsRefused(_ text: String) {
        #expect(throws: ClaudeSettingsEdit.Unreadable.self) {
            try ClaudeSettingsEdit.connecting(text, command: Self.command)
        }
        #expect(throws: ClaudeSettingsEdit.Unreadable.self) {
            try ClaudeSettingsEdit.disconnecting(text)
        }
        #expect(ClaudeSettingsEdit.state(of: text, command: Self.command) == .unreadable)
    }
}

import Combine
import Foundation
import Testing
@testable import Cyclop

/// Тесты запросов в `ClaudeStore`: запрос приходит байтами, как от слушателя, ответ уходит
/// байтами в ретранслятор. Сокет, ретранслятор и файл настроек — подделки и временные файлы.
@MainActor
struct ClaudeRequestTests {

    private typealias Rig = ClaudeStoreTests.Rig

    private static let colors = """
        {"questions":[{"question":"Какой цвет?","header":"Цвет","options":[\
        {"label":"Красный","description":"Яркий"},{"label":"Синий","description":"Спокойный"}],"multiSelect":false}]}
        """

    private static let two = """
        {"questions":[\
        {"question":"Язык?","header":"Язык","options":[{"label":"Swift","description":"Родной"},{"label":"Rust","description":"Быстрый"}],"multiSelect":false},\
        {"question":"Тесты?","header":"Тесты","options":[{"label":"Да","description":""},{"label":"Нет","description":""}],"multiSelect":false}]}
        """

    private static func body(session pid: Int, tool: String, input: String) -> String {
        #"{"session_id":"session-\#(pid)","hook_event_name":"PermissionRequest","tool_name":"\#(tool)","tool_input":\#(input)}"#
    }

    private static func question(_ pid: Int = 7, input: String = colors) -> String {
        body(session: pid, tool: "AskUserQuestion", input: input)
    }

    private static func reply(_ updatedInput: String) -> String {
        #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":\#(updatedInput)}}}"#
    }

    /// Подключённый Cyclop, вкладка на рейке и одна ждущая сессия.
    private func ready(sessions: [Int] = [7]) throws -> Rig {
        let rig = try Rig()
        try rig.writeSettings(try ClaudeSettingsEdit.connecting("{}", command: Rig.command))
        for pid in sessions { try rig.write(pid, status: "waiting") }
        rig.store.beginBackground()
        return rig
    }

    // MARK: - Приход

    @Test func aCommandAQuestionAndAPlanBecomeRequestsOfTheRightKind() throws {
        let rig = try ready()

        rig.listener.arrive(Self.body(session: 7, tool: "Bash", input: #"{"command":"ls"}"#))
        rig.listener.arrive(Self.question())
        rig.listener.arrive(Self.body(session: 7, tool: "ExitPlanMode", input: ##"{"plan":"# План"}"##))

        #expect(rig.store.requests.map(\.kind) == [.permission, .question, .plan])
        #expect(rig.store.requests.map(\.toolName) == ["Bash", "AskUserQuestion", "ExitPlanMode"])
        #expect(rig.store.requests.allSatisfy { $0.pid == 7 })
    }

    @Test func aQuestionKeepsItsTextOptionsAndDescriptions() throws {
        let rig = try ready()

        rig.listener.arrive(Self.question())

        let question = try #require(rig.store.requests.first?.current)
        #expect(question.text == "Какой цвет?")
        #expect(question.header == "Цвет")
        #expect(question.options == [.init(label: "Красный", description: "Яркий"), .init(label: "Синий", description: "Спокойный")])
        #expect(question.multiSelect == false)
    }

    @Test func requestsAreOldestFirst() throws {
        let rig = try ready(sessions: [7, 8])

        rig.listener.arrive(Self.question(8))
        rig.moment = rig.moment.addingTimeInterval(5)
        rig.listener.arrive(Self.question(7))

        #expect(rig.store.requests.map(\.pid) == [8, 7])
    }

    @Test func aRequestOfAnUnknownSessionIsClosedWithoutAnAnswer() throws {
        let rig = try ready()

        let relay = rig.listener.arrive(Self.question(99))

        #expect(rig.store.requests.isEmpty)
        #expect(relay.isClosed)
        #expect(relay.replies.isEmpty)
    }

    @Test func aRequestThatDoesNotParseIsClosedWithoutAnAnswer() throws {
        let rig = try ready()

        let broken = rig.listener.arrive("{не json")
        let noTool = rig.listener.arrive(#"{"session_id":"session-7"}"#)

        #expect(rig.store.requests.isEmpty)
        #expect(broken.isClosed && broken.replies.isEmpty)
        #expect(noTool.isClosed && noTool.replies.isEmpty)
    }

    @Test func aSessionStartedAMomentAgoIsKnownBecauseTheFolderIsReadOnArrival() throws {
        let rig = try ready()
        try rig.write(21, status: "waiting")

        rig.listener.arrive(Self.question(21))

        #expect(rig.store.requests.map(\.pid) == [21])
    }

    @Test func aFoldedIdleSessionStillOwnsItsRequest() throws {
        let rig = try ready(sessions: [])
        try rig.write(30, status: "idle", ago: 7200)

        rig.listener.arrive(Self.question(30))

        #expect(rig.store.requests.map(\.pid) == [30])
    }

    @Test func aSubagentsRequestIsShownUnderItsSession() throws {
        let rig = try ready()

        rig.listener.arrive(
            #"{"session_id":"session-7","agent_id":"ae23","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"ls"}}"#)

        #expect(rig.store.requests.map(\.pid) == [7])
    }

    // MARK: - Ответ на вопрос

    @Test func anOptionAnswersWithTheQuestionsAsReceivedAndTheAnswerKeyedByItsText() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question())
        let id = try #require(rig.store.requests.first?.id)

        rig.store.answer(id, with: "Синий")

        #expect(
            relay.replies == [
                Self.reply(
                    #"{"questions":[{"question":"Какой цвет?","header":"Цвет","options":[{"label":"Красный","description":"Яркий"},{"label":"Синий","description":"Спокойный"}],"multiSelect":false}],"answers":{"Какой цвет?":"Синий"}}"#
                )
            ])
        #expect(rig.store.requests.isEmpty)
    }

    @Test func theOwnersOwnTextIsAnAnswerToo() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question())
        let id = try #require(rig.store.requests.first?.id)

        rig.store.answer(id, with: "Зелёный \"как\" трава\nи ёлка")

        let sent = try #require(relay.replies.first)
        #expect(sent.contains(#""answers":{"Какой цвет?":"Зелёный \"как\" трава\nи ёлка"}"#))
        #expect(JSONTree(parsing: sent) != nil)
    }

    @Test func severalQuestionsAreAskedOneByOneAndSentOnceAfterTheLast() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question(input: Self.two))
        let id = try #require(rig.store.requests.first?.id)

        #expect(rig.store.requests.first?.current?.text == "Язык?")
        rig.store.answer(id, with: "Swift")
        #expect(rig.store.requests.first?.current?.text == "Тесты?")
        #expect(relay.replies.isEmpty)

        rig.store.answer(id, with: "Да")
        #expect(relay.replies.count == 1)
        #expect(relay.replies[0].contains(#""answers":{"Язык?":"Swift","Тесты?":"Да"}"#))
        #expect(rig.store.requests.isEmpty)
    }

    @Test func goingBackLetsTheEarlierQuestionBeAnsweredAgain() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question(input: Self.two))
        let id = try #require(rig.store.requests.first?.id)

        rig.store.answer(id, with: "Swift")
        rig.store.goBack(id)
        #expect(rig.store.requests.first?.current?.text == "Язык?")
        rig.store.goBack(id)
        #expect(rig.store.requests.first?.current?.text == "Язык?")

        rig.store.answer(id, with: "Rust")
        rig.store.answer(id, with: "Нет")
        #expect(relay.replies.count == 1)
        #expect(relay.replies[0].contains(#""answers":{"Язык?":"Rust","Тесты?":"Нет"}"#))
    }

    @Test func aMultiSelectQuestionIsNotAnsweredInThePanel() throws {
        let rig = try ready()
        let multi = Self.colors.replacingOccurrences(of: #""multiSelect":false"#, with: #""multiSelect":true"#)
        let relay = rig.listener.arrive(Self.question(input: multi))
        let id = try #require(rig.store.requests.first?.id)

        rig.store.answer(id, with: "Синий")

        #expect(rig.store.requests.first?.isAnsweredInPanel == false)
        #expect(rig.store.requests.first?.current == nil)
        #expect(relay.replies.isEmpty)
        #expect(relay.isClosed == false)
    }

    @Test func aRequestAnsweredOnceIgnoresALaterAnswer() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question())
        let id = try #require(rig.store.requests.first?.id)

        rig.store.answer(id, with: "Синий")
        rig.store.answer(id, with: "Красный")

        #expect(relay.replies.count == 1)
    }

    @Test func aCommandIsNotAnsweredByAnOption() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.body(session: 7, tool: "Bash", input: #"{"command":"ls"}"#))
        let id = try #require(rig.store.requests.first?.id)

        rig.store.answer(id, with: "Синий")

        #expect(relay.replies.isEmpty)
        #expect(rig.store.requests.count == 1)
    }

    // MARK: - Запрос уходит

    @Test func aHangUpTakesItsRequestAndNoOther() throws {
        let rig = try ready(sessions: [7, 8])
        let first = rig.listener.arrive(Self.question(7))
        rig.listener.arrive(Self.question(8))

        first.hangUp()

        #expect(rig.store.requests.map(\.pid) == [8])
    }

    @Test func aStateChangeAfterTheArrivalDropsTheRequestAndClosesItsRelay() throws {
        let rig = try ready(sessions: [7, 8])
        let first = rig.listener.arrive(Self.question(7))
        let second = rig.listener.arrive(Self.question(8))

        // Ответили в самом Claude: сессия снова работает, файл переписан позже запроса.
        rig.moment = rig.moment.addingTimeInterval(3)
        try rig.write(7, status: "busy")
        rig.store.reload()

        #expect(rig.store.requests.map(\.pid) == [8])
        #expect(first.isClosed && first.replies.isEmpty)
        #expect(!second.isClosed)
        // Сессия остаётся в списке; следующий запрос — уже первый.
        #expect(rig.store.sessions.contains { $0.pid == 7 && $0.state == .working })
        #expect(rig.store.requests.first?.pid == 8)
    }

    @Test func aFinishedSessionTakesItsRequestToo() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question())

        rig.moment = rig.moment.addingTimeInterval(3)
        try rig.write(7, status: "idle")
        rig.store.reload()

        #expect(rig.store.requests.isEmpty)
        #expect(relay.isClosed && relay.replies.isEmpty)
    }

    @Test func aReadingThatStillShowsTheOlderStateDoesNotDropAFreshRequest() throws {
        let rig = try ready(sessions: [])
        // Файл ещё говорит «работает» с прежнего момента: запрос обогнал запись файла.
        try rig.write(7, status: "busy", ago: 10)
        rig.store.reload()
        let relay = rig.listener.arrive(Self.question())

        rig.store.reload()
        #expect(rig.store.requests.count == 1)
        #expect(!relay.isClosed)

        // Файл догнал запрос: «ждёт» с новой отметкой — запрос остаётся.
        rig.moment = rig.moment.addingTimeInterval(1)
        try rig.write(7, status: "waiting")
        rig.store.reload()
        #expect(rig.store.requests.count == 1)
        #expect(!relay.isClosed)
    }

    @Test func aSessionStillWaitingKeepsItsRequestsAfterTheFileIsRewritten() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question())

        rig.moment = rig.moment.addingTimeInterval(3)
        try rig.write(7, status: "waiting")
        rig.store.reload()

        #expect(rig.store.requests.count == 1)
        #expect(!relay.isClosed)
    }

    @Test func aSessionThatLeavesTheListTakesItsRequestsAndNoOthers() throws {
        let rig = try ready(sessions: [7, 8])
        let first = rig.listener.arrive(Self.question(7))
        let second = rig.listener.arrive(Self.question(8))
        let third = rig.listener.arrive(Self.body(session: 7, tool: "Bash", input: #"{"command":"ls"}"#))

        rig.alive.remove(7)
        rig.store.reload()
        // Из списка сессия ушла сразу, а запрос снимается со второго чтения подряд.
        #expect(rig.store.sessions.map(\.pid) == [8])
        #expect(rig.store.requests.count == 3)
        rig.store.reload()

        #expect(rig.store.requests.map(\.pid) == [8])
        #expect(first.isClosed && first.replies.isEmpty)
        #expect(third.isClosed && third.replies.isEmpty)
        #expect(!second.isClosed)
    }

    @Test func aRemovedFileTakesItsRequest() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question())

        try FileManager.default.removeItem(at: rig.folder.appendingPathComponent("7.json"))
        rig.store.reload()
        rig.store.reload()

        #expect(rig.store.requests.isEmpty)
        #expect(relay.isClosed && relay.replies.isEmpty)
    }

    @Test func aSessionFileThatDoesNotReadOnceKeepsItsRequest() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question())
        let file = rig.folder.appendingPathComponent("7.json")
        let good = try Data(contentsOf: file)

        // Файл пишется на лету: одно чтение его не прочло.
        try Data("{ \"pid\": 7,".utf8).write(to: file)
        rig.store.reload()
        #expect(rig.store.sessions.isEmpty)
        #expect(rig.store.requests.count == 1)
        #expect(!relay.isClosed)

        // Файл прочёлся: счёт начинается заново, и одно новое пропущенное чтение снова ничего не стоит.
        try good.write(to: file)
        rig.store.reload()
        try Data("{ \"pid\": 7,".utf8).write(to: file)
        rig.store.reload()
        #expect(rig.store.requests.count == 1)
        #expect(!relay.isClosed)

        // Два подряд — сессия правда пропала.
        rig.store.reload()
        #expect(rig.store.requests.isEmpty)
        #expect(relay.isClosed && relay.replies.isEmpty)
    }

    @Test func aHookThatEndedLeavesItsSessionListedAsWaiting() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question())

        relay.hangUp()
        rig.store.reload()

        #expect(rig.store.requests.isEmpty)
        #expect(rig.store.sessions.map(\.state) == [.waiting])
    }

    @Test func aSubagentsRequestOfAnUnknownSessionIsClosedWithoutAnAnswer() throws {
        let rig = try ready()

        let relay = rig.listener.arrive(
            #"{"session_id":"session-99","agent_id":"ae23","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"ls"}}"#)

        #expect(rig.store.requests.isEmpty)
        #expect(relay.isClosed && relay.replies.isEmpty)
    }

    @Test func endingBackgroundWorkClosesEveryRequestWithoutAnAnswer() throws {
        let rig = try ready(sessions: [7, 8])
        let first = rig.listener.arrive(Self.question(7))
        let second = rig.listener.arrive(Self.question(8))

        rig.store.endBackground()

        #expect(rig.store.requests.isEmpty)
        #expect(first.isClosed && first.replies.isEmpty)
        #expect(second.isClosed && second.replies.isEmpty)
    }

    @Test func disconnectingClosesEveryRequestWithoutAnAnswer() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question())

        rig.store.disconnect()

        #expect(rig.store.requests.isEmpty)
        #expect(relay.isClosed && relay.replies.isEmpty)
    }

    @Test func nothingOfARequestIsWrittenToDisk() throws {
        let rig = try ready()
        let before = rig.settingsText()
        rig.listener.arrive(Self.question())
        let id = try #require(rig.store.requests.first?.id)
        rig.store.answer(id, with: "Уникальныйответ")

        let base = rig.folder.deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for file in files where !file.hasDirectoryPath {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!text.contains("Какой цвет?") && !text.contains("Уникальныйответ"))
        }
        #expect(rig.settingsText() == before)
    }

    // MARK: - Свой ответ и черновик

    @Test func anEmptyOwnAnswerSendsNothing() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question())
        let id = try #require(rig.store.requests.first?.id)

        rig.store.answer(id, with: "")
        rig.store.answer(id, with: "  \n ")

        #expect(relay.replies.isEmpty)
        #expect(rig.store.requests.first?.answers.isEmpty == true)
    }

    @Test func aTypedAnswerToOneQuestionAndAButtonForAnotherAreSentTogether() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question(input: Self.two))
        let id = try #require(rig.store.requests.first?.id)

        rig.store.answer(id, with: "Свой язык: Zig")
        rig.store.answer(id, with: "Да")

        #expect(relay.replies.count == 1)
        #expect(relay.replies[0].contains(#""answers":{"Язык?":"Свой язык: Zig","Тесты?":"Да"}"#))
    }

    @Test func aDraftIsKeptWhileTheFieldIsOpenAndIsNotPublishedByTheStore() throws {
        let rig = try ready()
        rig.listener.arrive(Self.question())
        let id = try #require(rig.store.requests.first?.id)
        var published = 0
        let watch = rig.store.objectWillChange.sink { published += 1 }

        #expect(rig.store.draft(of: id) == nil)
        rig.store.openField(of: id)
        for text in ["П", "Пр", "При", "Привет"] { rig.store.setDraft(text, of: id) }

        #expect(rig.store.draft(of: id) == "Привет")
        #expect(published == 0)
        watch.cancel()
    }

    @Test func aDraftNeedsAnOpenFieldAndAClosedFieldForgetsIt() throws {
        let rig = try ready()
        rig.listener.arrive(Self.question())
        let id = try #require(rig.store.requests.first?.id)

        rig.store.setDraft("мимо", of: id)
        #expect(rig.store.draft(of: id) == nil)

        rig.store.openField(of: id)
        rig.store.setDraft("текст", of: id)
        rig.store.openField(of: id)
        #expect(rig.store.draft(of: id) == "текст")

        rig.store.closeField(of: id)
        #expect(rig.store.draft(of: id) == nil)
    }

    @Test func aDraftGoesWithItsRequestAnswerOrNot() throws {
        let rig = try ready(sessions: [7, 8])
        let first = rig.listener.arrive(Self.question(7))
        rig.listener.arrive(Self.question(8))
        let one = try #require(rig.store.requests.first { $0.pid == 7 }?.id)
        let two = try #require(rig.store.requests.first { $0.pid == 8 }?.id)
        rig.store.openField(of: one)
        rig.store.setDraft("недописано", of: one)
        rig.store.openField(of: two)
        rig.store.setDraft("другое", of: two)

        first.hangUp()
        #expect(rig.store.draft(of: one) == nil)
        #expect(rig.store.draft(of: two) == "другое")

        rig.store.answer(two, with: "Синий")
        #expect(rig.store.draft(of: two) == nil)
    }

    @Test func answeringOrGoingBackClosesTheField() throws {
        let rig = try ready()
        rig.listener.arrive(Self.question(input: Self.two))
        let id = try #require(rig.store.requests.first?.id)
        rig.store.openField(of: id)
        rig.store.setDraft("недописано", of: id)

        rig.store.answer(id, with: "Swift")
        #expect(rig.store.draft(of: id) == nil)

        rig.store.openField(of: id)
        rig.store.goBack(id)
        #expect(rig.store.draft(of: id) == nil)
    }

    @Test func aRequestThatLeavesWithTheListClosesItsField() throws {
        let rig = try ready()
        rig.listener.arrive(Self.question())
        let id = try #require(rig.store.requests.first?.id)
        rig.store.openField(of: id)
        rig.store.setDraft("недописано", of: id)

        rig.alive.remove(7)
        rig.store.reload()
        rig.store.reload()

        #expect(rig.store.draft(of: id) == nil)
    }

    @Test func aFieldThatGoesWithItsRequestLeavesNoKeyboardFlag() throws {
        let rig = try ready(sessions: [7, 8])
        rig.listener.arrive(Self.question(7))
        let one = try #require(rig.store.requests.first?.id)
        rig.store.openField(of: one)
        rig.store.setFieldShown(true)
        #expect(rig.store.fieldShown)

        // Ответ своими словами: поле уходит с запросом, а следующий приходит с закрытым полем.
        rig.store.answer(one, with: "своё")
        rig.listener.arrive(Self.question(8))
        let two = try #require(rig.store.requests.first?.id)

        #expect(rig.store.fieldShown == false)
        #expect(rig.store.draft(of: two) == nil)
    }

    @Test func aFieldOfAnotherRequestKeepsTheFlagWhileItsDraftIsLeft() throws {
        let rig = try ready(sessions: [7, 8])
        let first = rig.listener.arrive(Self.question(7))
        rig.listener.arrive(Self.question(8))
        let one = try #require(rig.store.requests.first { $0.pid == 7 }?.id)
        let two = try #require(rig.store.requests.first { $0.pid == 8 }?.id)
        rig.store.openField(of: two)
        rig.store.setFieldShown(true)

        first.hangUp()
        #expect(rig.store.draft(of: one) == nil)
        #expect(rig.store.fieldShown)

        rig.store.closeField(of: two)
        #expect(rig.store.fieldShown == false)
    }

    @Test func aRequestThatArrivesAfterTheSocketClosedIsClosedAndNotQueued() throws {
        let rig = try ready()
        // Запрос уже ехал на главную очередь, а вкладку выключили.
        rig.store.endBackground()

        let relay = rig.listener.arrive(Self.question())

        #expect(rig.store.requests.isEmpty)
        #expect(relay.isClosed && relay.replies.isEmpty)
        #expect(rig.store.hasUnseenRequest == false)
    }

    @Test func aRequestThatArrivesAfterDisconnectIsClosedAndNotQueued() throws {
        let rig = try ready()
        rig.store.disconnect()

        let relay = rig.listener.arrive(Self.question())

        #expect(rig.store.requests.isEmpty)
        #expect(relay.isClosed && relay.replies.isEmpty)
    }

    // MARK: - Разрешение

    private static let touch = """
        {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch x"}],"behavior":"allow","destination":"localSettings"}
        """
    private static let folder = #"{"type":"addDirectories","directories":["/tmp/p"],"destination":"session"}"#
    private static let mode = #"{"type":"setMode","mode":"acceptEdits","destination":"session"}"#

    private static func command(_ suggestions: [String]?, tool: String = "Bash", input: String = #"{"command":"touch x"}"#) -> String {
        let list = suggestions.map { #","permission_suggestions":[\#($0.joined(separator: ","))]"# } ?? ""
        return #"{"session_id":"session-7","hook_event_name":"PermissionRequest","tool_name":"\#(tool)","tool_input":\#(input)\#(list)}"#
    }

    private static func decision(_ members: String) -> String {
        #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{\#(members)}}}"#
    }

    @Test func allowSendsABareAllowAndEndsTheRequest() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.command([Self.touch, Self.folder, Self.mode]))
        let id = try #require(rig.store.requests.first?.id)

        rig.store.allow(id)

        #expect(relay.replies == [Self.decision(#""behavior":"allow""#)])
        #expect(rig.store.requests.isEmpty)
    }

    @Test func alwaysAllowEchoesTheRuleEntriesAndLeavesTheSessionOnlyOnesOut() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.command([Self.touch, Self.folder, Self.mode]))
        let id = try #require(rig.store.requests.first?.id)

        #expect(rig.store.requests.first?.rule == "Bash(touch x)")
        rig.store.alwaysAllow(id)

        #expect(relay.replies == [Self.decision(#""behavior":"allow","updatedPermissions":[\#(Self.touch)]"#)])
        #expect(rig.store.requests.isEmpty)
    }

    @Test func aWebRequestsRuleIsShownAndEchoed() throws {
        let rig = try ready()
        let web = #"{"type":"addRules","destination":"localSettings","rules":[{"toolName":"WebFetch","ruleContent":"domain:example.com"}],"behavior":"allow"}"#
        let relay = rig.listener.arrive(Self.command([web], tool: "WebFetch", input: #"{"url":"https://example.com/a"}"#))
        let id = try #require(rig.store.requests.first?.id)

        #expect(rig.store.requests.first?.rule == "WebFetch(domain:example.com)")
        rig.store.alwaysAllow(id)

        #expect(relay.replies == [Self.decision(#""behavior":"allow","updatedPermissions":[\#(web)]"#)])
    }

    @Test func anEditWithOnlyASessionModeHasNoAlwaysAllow() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(
            Self.command([Self.mode], tool: "Edit", input: #"{"file_path":"/tmp/a.txt","old_string":"a","new_string":"b"}"#))
        let id = try #require(rig.store.requests.first?.id)

        #expect(rig.store.requests.first?.rule == nil)
        rig.store.alwaysAllow(id)

        #expect(relay.replies.isEmpty)
        #expect(rig.store.requests.count == 1)
    }

    @Test func aRequestWithoutSuggestionsHasNoAlwaysAllow() throws {
        let rig = try ready()
        rig.listener.arrive(Self.command(nil))

        #expect(rig.store.requests.first?.rule == nil)
        #expect(rig.store.requests.first?.rules.isEmpty == true)
    }

    @Test func aRuleThatIsNotOneLineIsNotOffered() throws {
        let rig = try ready()
        let long = #"{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"a\nb"}],"behavior":"allow","destination":"localSettings"}"#
        rig.listener.arrive(Self.command([long]))

        #expect(rig.store.requests.first?.rule == nil)
    }

    @Test func aRuleWithoutContentIsJustTheTool() throws {
        let rig = try ready()
        let whole = #"{"type":"addRules","rules":[{"toolName":"WebSearch"}],"behavior":"allow","destination":"localSettings"}"#
        rig.listener.arrive(Self.command([whole], tool: "WebSearch", input: #"{"query":"swift"}"#))

        #expect(rig.store.requests.first?.rule == "WebSearch")
    }

    @Test func denySendsTheFixedTextWithNoReason() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.command([Self.touch]))
        let id = try #require(rig.store.requests.first?.id)

        rig.store.deny(id)

        #expect(relay.replies == [Self.decision(#""behavior":"deny","message":"Denied from Cyclop""#)])
        #expect(rig.store.requests.isEmpty)
    }

    @Test func allowAndDenyDoNotAnswerAQuestionOrAPlan() throws {
        let rig = try ready()
        let question = rig.listener.arrive(Self.question())
        let plan = rig.listener.arrive(Self.body(session: 7, tool: "ExitPlanMode", input: ##"{"plan":"# План"}"##))
        let ids = rig.store.requests.map(\.id)

        for id in ids {
            rig.store.allow(id)
            rig.store.alwaysAllow(id)
            rig.store.deny(id)
        }

        #expect(question.replies.isEmpty && plan.replies.isEmpty)
        #expect(rig.store.requests.count == 2)
    }

    @Test func aCommandShowsAsTheCommandAndAFileAsThePath() throws {
        let rig = try ready()
        rig.listener.arrive(Self.command(nil, input: #"{"command":"git status"}"#))
        rig.listener.arrive(Self.command(nil, tool: "Write", input: #"{"file_path":"/tmp/a.txt","content":"x"}"#))
        rig.listener.arrive(Self.command(nil, tool: "Custom", input: #"{"a":1}"#))
        let long = String(repeating: "я", count: 5000)
        rig.listener.arrive(Self.command(nil, input: #"{"command":"\#(long)"}"#))

        let details = rig.store.requests.map(\.detail)
        #expect(details[0] == "git status")
        #expect(details[1] == "/tmp/a.txt")
        #expect(details[2] == #"{"a":1}"#)
        #expect(details[3].count <= 401 && details[3].hasSuffix("…"))
    }

    // MARK: - План

    private static func plan(_ text: String) -> String {
        body(session: 7, tool: "ExitPlanMode", input: #"{"plan":\#(JSONTree.quote(text))}"#)
    }

    @Test func approvingAPlanRepeatsTheToolsInput() throws {
        let rig = try ready()
        let input = ##"{"plan":"# План\n\nСделать","allowedPrompts":[{"tool":"Bash","prompt":"run tests"}]}"##
        let relay = rig.listener.arrive(Self.body(session: 7, tool: "ExitPlanMode", input: input))
        let id = try #require(rig.store.requests.first?.id)

        rig.store.approve(id)

        #expect(relay.replies == [Self.decision(#""behavior":"allow","updatedInput":\#(input)"#)])
        #expect(rig.store.requests.isEmpty)
    }

    @Test func sendingAPlanBackDeniesWithTheRemarks() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.plan("# План"))
        let id = try #require(rig.store.requests.first?.id)

        rig.store.sendBack(id, remarks: "Без миграции, \"пока\"")

        #expect(relay.replies == [Self.decision(#""behavior":"deny","message":"Без миграции, \"пока\"""#)])
        #expect(rig.store.requests.isEmpty)
    }

    @Test func emptyRemarksSendNothingAndOnlyAPlanIsApprovedOrSentBack() throws {
        let rig = try ready()
        let plan = rig.listener.arrive(Self.plan("# План"))
        let command = rig.listener.arrive(Self.command(nil))
        let planID = try #require(rig.store.requests.first { $0.kind == .plan }?.id)
        let commandID = try #require(rig.store.requests.first { $0.kind == .permission }?.id)

        rig.store.sendBack(planID, remarks: "  ")
        rig.store.approve(commandID)
        rig.store.sendBack(commandID, remarks: "нет")

        #expect(plan.replies.isEmpty && command.replies.isEmpty)
        #expect(rig.store.requests.count == 2)
    }

    @Test func aPlansTitleIsItsFirstHeadingAndTheBeginningFollows() throws {
        let rig = try ready()
        rig.listener.arrive(Self.plan("Вступление\n\n## План миграции\n\nШаг один\nШаг два\n"))

        let request = try #require(rig.store.requests.first)
        #expect(request.planTitle == "План миграции")
        #expect(request.planBeginning == "Вступление\nШаг один\nШаг два")
    }

    @Test func aPlanWithoutAHeadingTitlesItselfByItsFirstLine() throws {
        let rig = try ready()
        rig.listener.arrive(Self.plan("\n  Сначала тесты\nПотом код"))

        let request = try #require(rig.store.requests.first)
        #expect(request.planTitle == "Сначала тесты")
        #expect(request.planBeginning == "Потом код")
    }

    @Test func aPlanOfFiftyThousandCharactersIsCutToItsBeginning() throws {
        let rig = try ready()
        let text = "# Большой\n" + String(repeating: "строка плана, довольно длинная\n", count: 1700)
        #expect(text.count > 50_000)

        rig.listener.arrive(Self.plan(text))

        let request = try #require(rig.store.requests.first)
        #expect(request.planTitle == "Большой")
        #expect(request.planBeginning.count <= 601)
        #expect(request.planBeginning.hasPrefix("строка плана"))
    }

    @Test func aPlanWithoutTextStillHasABeginningAndATitleThatAreEmpty() throws {
        let rig = try ready()
        rig.listener.arrive(Self.body(session: 7, tool: "ExitPlanMode", input: "{}"))

        let request = try #require(rig.store.requests.first)
        #expect(request.planTitle.isEmpty && request.planBeginning.isEmpty)
    }

    // MARK: - Непросмотренный запрос

    @Test func anArrivalRaisesTheUnseenFlagAndMarkingClearsIt() throws {
        let rig = try ready()
        #expect(!rig.store.hasUnseenRequest)

        rig.listener.arrive(Self.question())
        #expect(rig.store.hasUnseenRequest)

        rig.store.markSeen()
        #expect(!rig.store.hasUnseenRequest)
        #expect(rig.store.requests.count == 1)
    }

    @Test func theFlagStaysUntilTheLastUnseenRequestIsGone() throws {
        let rig = try ready(sessions: [7, 8])
        let first = rig.listener.arrive(Self.question(7))
        let second = rig.listener.arrive(Self.question(8))

        first.hangUp()
        #expect(rig.store.hasUnseenRequest)

        second.hangUp()
        #expect(!rig.store.hasUnseenRequest)
    }

    @Test func aRequestAnsweredInThePanelClearsTheFlag() throws {
        let rig = try ready()
        rig.listener.arrive(Self.body(session: 7, tool: "Bash", input: #"{"command":"ls"}"#))
        let id = try #require(rig.store.requests.first?.id)

        rig.store.allow(id)

        #expect(!rig.store.hasUnseenRequest)
    }

    @Test func aSeenRequestGoingAwayDoesNotClearTheFlagOfANewerOne() throws {
        let rig = try ready(sessions: [7, 8])
        let seen = rig.listener.arrive(Self.question(7))
        rig.store.markSeen()
        rig.listener.arrive(Self.question(8))
        #expect(rig.store.hasUnseenRequest)

        seen.hangUp()

        #expect(rig.store.hasUnseenRequest)
    }

    @Test func aSeenRequestGoingAwayLeavesTheFlagDown() throws {
        let rig = try ready()
        let relay = rig.listener.arrive(Self.question())
        rig.store.markSeen()

        relay.hangUp()

        #expect(!rig.store.hasUnseenRequest)
    }

    @Test func switchingTheTabOffClearsTheFlagAndTellsTheListener() throws {
        let rig = try ready()
        var changes = 0
        rig.store.onUnseenChange = { changes += 1 }
        rig.listener.arrive(Self.question())
        #expect(changes == 1)

        rig.store.endBackground()

        #expect(!rig.store.hasUnseenRequest)
        #expect(changes == 2)
    }

    // MARK: - Выезд панели

    @Test func everyArrivalIsAnnouncedEvenWhileTheFlagIsAlreadyUp() throws {
        let rig = try ready(sessions: [7, 8])
        var arrivals = 0
        rig.store.onArrival = { arrivals += 1 }

        rig.listener.arrive(Self.question(7))
        rig.listener.arrive(Self.question(8))
        // Запрос без сессии закрывается без ответа и не приход.
        rig.listener.arrive(Self.question(99))

        #expect(arrivals == 2)
    }

    @Test func theLastRequestGoingAwayIsAnnouncedOnceHoweverItLeaves() throws {
        let rig = try ready(sessions: [7, 8, 9])
        var gone = 0
        rig.store.onRequestsGone = { gone += 1 }
        let hungUp = rig.listener.arrive(Self.question(7))
        rig.listener.arrive(Self.body(session: 8, tool: "Bash", input: #"{"command":"ls"}"#))
        rig.listener.arrive(Self.question(9))

        // Один ушёл по обрыву, второй отвечен в панели: ещё остаётся третий.
        hungUp.hangUp()
        rig.store.allow(try #require(rig.store.requests.first { $0.kind == .permission }?.id))
        #expect(gone == 0)

        // Третий отвечен в самом Claude: сессия снова работает.
        rig.moment = rig.moment.addingTimeInterval(3)
        try rig.write(9, status: "busy")
        rig.store.reload()

        #expect(rig.store.requests.isEmpty)
        #expect(gone == 1)
    }

    @Test func disconnectingAnnouncesThatTheRequestsAreGone() throws {
        let rig = try ready()
        rig.listener.arrive(Self.question())
        var gone = 0
        rig.store.onRequestsGone = { gone += 1 }

        rig.store.disconnect()

        #expect(gone == 1)
    }

    @Test func anEmptyListIsNotAnnouncedAsGone() throws {
        let rig = try ready()
        var gone = 0
        rig.store.onRequestsGone = { gone += 1 }

        rig.store.markSeen()
        rig.store.endBackground()

        #expect(gone == 0)
    }

    @Test func thePanelSlidesOutOnlyOntoAnIdleNotchWithTheSwitchOnAndTheTabShown() {
        #expect(RequestOpening.shouldOpen(enabled: true, claudeVisible: true, anyPanelActive: false))
        #expect(!RequestOpening.shouldOpen(enabled: false, claudeVisible: true, anyPanelActive: false))
        #expect(!RequestOpening.shouldOpen(enabled: true, claudeVisible: false, anyPanelActive: false))
        #expect(!RequestOpening.shouldOpen(enabled: true, claudeVisible: true, anyPanelActive: true))
    }

    // MARK: - Строка

    @Test func theRowOfASessionKnowsItsRequestAndTheRequestItsSession() throws {
        let rig = try ready(sessions: [7, 8])
        rig.listener.arrive(Self.question(8))
        let session = try #require(rig.store.sessions.first { $0.pid == 8 })
        let other = try #require(rig.store.sessions.first { $0.pid == 7 })

        let request = try #require(rig.store.request(forSession: session))
        #expect(rig.store.session(for: request)?.pid == 8)
        #expect(rig.store.request(forSession: other) == nil)
    }
}

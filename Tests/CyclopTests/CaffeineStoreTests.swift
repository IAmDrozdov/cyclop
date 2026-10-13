import Foundation
import Testing
@testable import Cyclop

/// Тесты на `CaffeineStore` — сессии «Кофеина» и удержание сна.
///
/// Единственный шов — порт питания: настоящая система не трогается, а
/// подставной порт считает, сколько удержаний сейчас взято. Файл настроек
/// стор не читает и не пишет, поэтому тесты его тоже не касаются.
@MainActor
struct CaffeineStoreTests {

    private final class FakePower: PowerPort {
        private(set) var holds = 0
        /// Что сейчас стоит в бите, и сколько раз его посылали.
        private(set) var bit = false
        private(set) var bitCalls: [Bool] = []
        var hasLid = true
        var lidClosed = false
        var onLidChange: (() -> Void)?
        var onMayHaveChanged: (() -> Void)?

        func holdIdleSleep() { holds += 1 }
        func releaseIdleSleep() { holds -= 1 }
        func setLidSleepDisabled(_ disabled: Bool) {
            bit = disabled
            bitCalls.append(disabled)
        }
        func moveLid(closed: Bool) {
            lidClosed = closed
            onLidChange?()
        }
    }

    private static func makeStore(
        minutes: Int = 60,
        lidClosedMode: Bool = false,
        hasLid: Bool = true,
        onMinutesChange: @escaping (Int) -> Void = { _ in },
        onLidClosedModeChange: @escaping (Bool) -> Void = { _ in }
    ) -> (store: CaffeineStore, power: FakePower) {
        let power = FakePower()
        power.hasLid = hasLid
        return (
            CaffeineStore(
                port: power, minutes: minutes, lidClosedMode: lidClosedMode,
                onMinutesChange: onMinutesChange, onLidClosedModeChange: onLidClosedModeChange
            ),
            power
        )
    }

    // MARK: - Бесконечная сессия

    @Test func anIndefiniteSessionTakesTheHoldAndKeepsItUntilStopped() {
        let (store, power) = Self.makeStore()
        store.startIndefinite()
        #expect(store.session == .indefinite)
        #expect(power.holds == 1)
        store.stop()
        #expect(store.session == .none)
        #expect(power.holds == 0)
    }

    /// Вторая сессия поверх первой не удваивает удержание: иначе одного
    /// «Остановить» не хватило бы, и Mac оставался бы бодрым без сессии.
    @Test func startingWhileOneRunsLeavesOneHold() {
        let (store, power) = Self.makeStore()
        store.startIndefinite()
        store.startIndefinite()
        store.startTimed()
        #expect(power.holds == 1)
        store.stop()
        #expect(power.holds == 0)
    }

    @Test func endingBackgroundWorkEndsTheSessionAndDropsTheHold() {
        let (store, power) = Self.makeStore()
        store.beginBackground()
        store.startIndefinite()
        store.endBackground()
        #expect(store.session == .none)
        #expect(power.holds == 0)
    }

    // MARK: - Сессия по таймеру

    @Test func aTimedSessionKeepsTheHoldBeforeItsDeadlineAndDropsItAtIt() {
        let (store, power) = Self.makeStore(minutes: 30)
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.startTimed(now: start)
        #expect(store.session == .timed(until: start.addingTimeInterval(30 * 60)))

        store.expireIfDue(now: start.addingTimeInterval(30 * 60 - 1))
        #expect(power.holds == 1)

        store.expireIfDue(now: start.addingTimeInterval(30 * 60))
        #expect(store.session == .none)
        #expect(power.holds == 0)
    }

    /// Срок, прошедший во сне, считается: после пробуждения первая же проверка
    /// заканчивает сессию, сколько бы часов Mac ни проспал.
    @Test func aDeadlinePassedDuringSleepEndsTheSession() {
        let (store, power) = Self.makeStore(minutes: 10)
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.startTimed(now: start)
        store.expireIfDue(now: start.addingTimeInterval(8 * 3600))
        #expect(store.session == .none)
        #expect(power.holds == 0)
    }

    @Test func zeroMinutesStartsNothing() {
        let (store, power) = Self.makeStore(minutes: 0)
        store.startTimed()
        #expect(store.session == .none)
        #expect(power.holds == 0)
    }

    @Test func expiryLeavesAnIndefiniteSessionAlone() {
        let (store, power) = Self.makeStore()
        store.startIndefinite()
        store.expireIfDue(now: .distantFuture)
        #expect(store.session == .indefinite)
        #expect(power.holds == 1)
    }

    // MARK: - Длительность

    @Test func aChangeOfDurationIsHandedBackToTheOwner() {
        var handed: [Int] = []
        let (store, _) = Self.makeStore(minutes: 60) { handed.append($0) }
        store.minutes = 90
        store.minutes = 90
        store.minutes = 5
        #expect(handed == [90, 5])
    }

    /// Значение мимо колеса, присвоенное в работе, тоже уходит владельцу уже исправленным.
    @Test func aCorrectedValueIsHandedBackCorrected() {
        var handed: [Int] = []
        let (store, _) = Self.makeStore(minutes: 60) { handed.append($0) }
        store.minutes = 62
        #expect(store.minutes == 60)
        #expect(handed.last == 60)
    }

    /// Файл правят руками: значение не с колеса читается как ближайшее на нём.
    @Test func aValueOffTheWheelIsReadAsTheNearestOnIt() {
        #expect(CaffeineStore.onWheel(62) == 60)
        #expect(CaffeineStore.onWheel(63) == 65)
        #expect(CaffeineStore.onWheel(-40) == 0)
        #expect(CaffeineStore.onWheel(99_999) == 23 * 60 + 55)
        #expect(Self.makeStore(minutes: 62).store.minutes == 60)
    }

    // MARK: - Режим крышки

    /// Режим сам по себе держит сон, но только пока крышка закрыта.
    @Test func theModeAloneTakesTheHoldOnlyWhileTheLidIsClosed() {
        let (store, power) = Self.makeStore(lidClosedMode: true)
        store.beginBackground()
        #expect(power.holds == 0)
        power.moveLid(closed: true)
        #expect(power.holds == 1)
        power.moveLid(closed: false)
        #expect(power.holds == 0)
    }

    /// Сессия кончилась при закрытой крышке — удержание остаётся, пока крышку
    /// не откроют.
    @Test func aSessionEndingWithTheLidClosedKeepsTheHold() {
        let (store, power) = Self.makeStore(lidClosedMode: true)
        store.beginBackground()
        store.startIndefinite()
        power.moveLid(closed: true)
        store.stop()
        #expect(power.holds == 1)
        power.moveLid(closed: false)
        #expect(power.holds == 0)
    }

    @Test func switchingTheModeOffClearsTheBitAndDropsTheLidsHold() {
        var handed: [Bool] = []
        let (store, power) = Self.makeStore(lidClosedMode: true) { _ in } onLidClosedModeChange: { handed.append($0) }
        store.beginBackground()
        power.moveLid(closed: true)
        #expect(power.bit)
        store.setLidClosedMode(false)
        #expect(!power.bit)
        #expect(power.holds == 0)
        store.setLidClosedMode(true)
        #expect(power.bit)
        #expect(power.holds == 1)
        #expect(handed == [false, true])
    }

    /// Начало фоновой работы посылает значение тумблера, в том числе «выключено»:
    /// бит, оставшийся от сбоя, прочитать нельзя, его только перезаписать.
    @Test func backgroundWorkSendsTheSwitchValueAndClearsTheBitOnTheWayOut() {
        let on = Self.makeStore(lidClosedMode: true)
        on.store.beginBackground()
        #expect(on.power.bitCalls == [true])
        on.store.endBackground()
        #expect(on.power.bit == false)

        let off = Self.makeStore(lidClosedMode: false)
        off.store.beginBackground()
        #expect(off.power.bitCalls == [false])
    }

    @Test func theMayHaveChangedSignalResendsTheBitOnlyWhileTheModeIsOn() {
        let (store, power) = Self.makeStore(lidClosedMode: true)
        store.beginBackground()
        power.onMayHaveChanged?()
        #expect(power.bitCalls == [true, true])
        store.setLidClosedMode(false)
        let before = power.bitCalls.count
        power.onMayHaveChanged?()
        #expect(power.bitCalls.count == before)
    }

    @Test func withNoLidTheBitIsNeverSet() {
        let (store, power) = Self.makeStore(lidClosedMode: true, hasLid: false)
        store.beginBackground()
        store.setLidClosedMode(true)
        #expect(store.lidClosedMode == false)
        #expect(power.bitCalls.isEmpty)
    }
}

import Testing
@testable import Cyclop

/// Порядок вкладок на рельсах: как читается сохранённый и как переставляется иконка.
struct RailOrderTests {
    private typealias Tab = NotchViewModel.Tab
    private static let defaults = Tab.defaultRails

    @Test func anEmptyFileGivesTheDefaultOrder() {
        #expect(RailOrder.normalized(left: [], right: []) == Self.defaults)
    }

    @Test func unknownAndRepeatedNamesAreDropped() {
        let order = RailOrder.normalized(
            left: ["shelf", "notes", "shelf", "claude"],
            right: ["claude", "settings"]
        )
        #expect(order.left.prefix(2) == [.shelf, .claude])
        #expect(order.right.first == .settings)
        #expect(!order.right.contains(.claude))
    }

    @Test func aTabTheFileDoesNotMentionJoinsItsDefaultRailAtTheEnd() {
        // Файл из версии без «Встреч»: вкладка дописывается в конец правой рельсы.
        let order = RailOrder.normalized(
            left: ["claude", "shelf", "clipboard", "snippets", "translate", "caffeine"],
            right: ["settings", "currency", "teleprompter"]
        )
        #expect(order.right == [.settings, .currency, .teleprompter, .meetings])
        #expect(order.left == Self.defaults.left)
    }

    @Test func everyTabEndsUpOnExactlyOneRail() {
        let order = RailOrder.normalized(left: ["settings", "currency"], right: ["shelf"])
        let all = order.left + order.right
        #expect(all.count == Tab.allCases.count)
        #expect(Set(all) == Set(Tab.allCases))
    }

    @Test func movingUpAndDownWithinARail() {
        let up = Self.defaults.moving(.translate, toRight: false, before: .shelf)
        #expect(up.left == [.claude, .translate, .shelf, .clipboard, .snippets, .caffeine])
        let down = Self.defaults.moving(.claude, toRight: false, before: .translate)
        #expect(down.left == [.shelf, .clipboard, .snippets, .claude, .translate, .caffeine])
        #expect(up.right == Self.defaults.right)
    }

    @Test func movingToTheOtherRail() {
        let order = Self.defaults.moving(.caffeine, toRight: true, before: .settings)
        #expect(order.left == [.claude, .shelf, .clipboard, .snippets, .translate])
        #expect(order.right == [.currency, .teleprompter, .meetings, .caffeine, .settings])
    }

    @Test func noNeighbourMeansTheEndOfTheRail() {
        let order = Self.defaults.moving(.settings, toRight: false, before: nil)
        #expect(order.left.last == .settings)
        #expect(!order.right.contains(.settings))
    }

    @Test func aHiddenNeighbourKeepsItsPlace() {
        // «Буфер» скрыт: видимый сосед сверху — «Полка», вставка идёт перед ней, скрытая вкладка не двигается.
        let order = Self.defaults.moving(.snippets, toRight: false, before: .shelf)
        #expect(order.left == [.claude, .snippets, .shelf, .clipboard, .translate, .caffeine])
    }

    @Test func movingToTheSamePlaceChangesNothing() {
        #expect(Self.defaults.moving(.shelf, toRight: false, before: .clipboard) == Self.defaults)
    }
}

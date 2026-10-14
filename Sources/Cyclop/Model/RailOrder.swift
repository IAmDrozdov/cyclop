/// Which tabs sit on which rail, top to bottom, hidden ones included.
struct RailOrder: Equatable {
    var left: [NotchViewModel.Tab]
    var right: [NotchViewModel.Tab]

    /// The saved order made whole: unknown and repeated names dropped, and a
    /// tab the file does not mention (one added in a later version) appended to
    /// its default rail, so every tab is on exactly one rail.
    static func normalized(left: [String], right: [String]) -> RailOrder {
        var seen = Set<NotchViewModel.Tab>()
        func tabs(_ raw: [String]) -> [NotchViewModel.Tab] {
            raw.compactMap(NotchViewModel.Tab.init(rawValue:)).filter { seen.insert($0).inserted }
        }
        var order = RailOrder(left: tabs(left), right: tabs(right))
        let defaults = NotchViewModel.Tab.defaultRails
        order.left += defaults.left.filter { !seen.contains($0) }
        order.right += defaults.right.filter { !seen.contains($0) }
        return order
    }

    /// `tab` taken off its rail and put on the chosen one before `before`, or
    /// at the end when `before` is nil or not on that rail.
    func moving(_ tab: NotchViewModel.Tab, toRight: Bool, before: NotchViewModel.Tab?) -> RailOrder {
        var order = self
        order.left.removeAll { $0 == tab }
        order.right.removeAll { $0 == tab }
        if toRight {
            order.right.insert(tab, at: before.flatMap(order.right.firstIndex(of:)) ?? order.right.endIndex)
        } else {
            order.left.insert(tab, at: before.flatMap(order.left.firstIndex(of:)) ?? order.left.endIndex)
        }
        return order
    }
}

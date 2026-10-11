import Foundation

/// The Chorus Deck shuffle.
///
/// Works like a deck of cards: every bird sings once before any bird repeats,
/// then the deck is reshuffled into a new order for the next round. The
/// reshuffle also keeps a minimum gap, so a bird that sang near the end of one
/// round cannot come straight back at the start of the next. With 20 birds,
/// the same bird is always at least 10 mornings apart.
///
/// The bird for a given morning is calculated from the calendar date alone.
/// Nothing is stored, so re-signing, updating, or even deleting and
/// reinstalling the app cannot reset the shuffle or cause an early repeat.
enum ShuffleDeck {
    /// Which slot of the deck (0..<count) sings on the given day.
    static func slot(count: Int, day: Int) -> Int {
        guard count > 1 else { return 0 }
        let safeDay = max(day, 0)
        return order(count: count, round: safeDay / count)[safeDay % count]
    }

    /// Whole days since 1 January 2026 in the phone's calendar.
    static func dayNumber(for date: Date, calendar: Calendar = .current) -> Int {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 1
        parts.day = 1
        let reference = calendar.startOfDay(for: calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0))
        let target = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: reference, to: target).day ?? 0
    }

    /// Fewest mornings allowed between two appearances of the same bird.
    static func minimumGap(count: Int) -> Int {
        min(count, max(2, count / 2))
    }

    /// The deck order for a round. Each round is built from the one before it,
    /// starting at round 0, so the result is always the same for the same inputs.
    static func order(count: Int, round: Int) -> [Int] {
        var current = Array(0..<count)
        guard count > 1 else { return current }

        // Round 0: a plain shuffle.
        var state = seed(for: 0)
        var i = count - 1
        while i > 0 {
            let j = Int(nextRandom(&state) % UInt64(i + 1))
            current.swapAt(i, j)
            i -= 1
        }
        guard round >= 1 else { return current }

        // Later rounds: draw one bird at a time, skipping any bird that sang too recently.
        let gap = minimumGap(count: count)
        for r in 1...round {
            state = seed(for: r)
            var lastPosition = [Int](repeating: 0, count: count)
            for (position, bird) in current.enumerated() { lastPosition[bird] = position }

            var remaining = Array(0..<count)
            var next: [Int] = []
            for position in 0..<count {
                let eligible = remaining.filter { (count - lastPosition[$0]) + position >= gap }
                let pick = eligible[Int(nextRandom(&state) % UInt64(eligible.count))]
                next.append(pick)
                remaining.removeAll { $0 == pick }
            }
            current = next
        }
        return current
    }

    private static func seed(for round: Int) -> UInt64 {
        UInt64(round) &* 0x9E3779B97F4A7C15 &+ 0xB5AD4ECEDA1CE2A9
    }

    /// SplitMix64: a small, well-known generator that gives identical results on every device.
    private static func nextRandom(_ state: inout UInt64) -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

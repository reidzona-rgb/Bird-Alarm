import Foundation

/// The Chorus Deck shuffle.
///
/// Works like a deck of cards: every slot is dealt once before the deck is
/// reshuffled for the next round. Higher-scoring birds fill several slots, so
/// the deal also keeps a minimum gap per bird: a bird cannot come back until
/// enough other birds have sung, never back to back, and never twice across a
/// day's alarms (each alarm takes the next card in the deal).
///
/// Every ring's bird is calculated from the calendar date and the alarm's
/// place in the day alone. Nothing is stored, so re-signing, updating, or
/// reinstalling the app cannot reset the shuffle or cause an early repeat.
enum ShuffleDeck {
    /// Which slot of the deck sings at position `index` of the endless deal.
    /// `keys[slot]` identifies the bird in that slot (0..<distinct birds).
    /// Within any `spread + 1` consecutive positions every bird is different
    /// (as long as the deck has that many birds), whatever the weighting.
    static func slot(keys: [Int], index: Int, spread: Int) -> Int {
        let count = keys.count
        guard count > 1 else { return 0 }
        let i = max(index, 0)
        return order(keys: keys, round: i / count, spread: spread)[i % count]
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

    /// How many other birds must sing before a bird may sing again.
    static func minimumGap(distinct: Int) -> Int {
        max(1, min(distinct - 1, distinct / 4))
    }

    private struct CacheKey: Hashable {
        let keys: [Int]
        let round: Int
        let spread: Int
    }
    private static var cache: [CacheKey: [Int]] = [:]
    private static let lock = NSLock()

    /// The deal order for a round (a list of slots). Each round continues from
    /// the one before it, starting at round 0, so the result is always the same
    /// for the same inputs.
    static func order(keys: [Int], round: Int, spread: Int) -> [Int] {
        lock.lock()
        defer { lock.unlock() }

        let count = keys.count
        guard count > 1 else { return Array(0..<count) }
        if let hit = cache[CacheKey(keys: keys, round: round, spread: spread)] { return hit }

        var start = 0
        var previous: [Int]?
        for r in stride(from: round - 1, through: 0, by: -1) {
            if let hit = cache[CacheKey(keys: keys, round: r, spread: spread)] {
                previous = hit
                start = r + 1
                break
            }
        }

        let distinct = (keys.max() ?? 0) + 1
        var firstSlot = [Int](repeating: 0, count: distinct)
        for (slot, key) in keys.enumerated().reversed() { firstSlot[key] = slot }
        let hard = max(0, min(spread, distinct - 1))
        let gap = max(minimumGap(distinct: distinct), hard)

        var result: [Int] = []
        for r in start...round {
            var lastSeen = [Int](repeating: Int.min / 2, count: distinct)
            if let previous {
                for (position, slot) in previous.enumerated() { lastSeen[keys[slot]] = position - count }
            }
            result = deal(keys: keys, round: r, lastSeen: &lastSeen, gap: gap, hard: hard, firstSlot: firstSlot)
            previous = result
        }

        if cache.count > 32 { cache.removeAll() }
        cache[CacheKey(keys: keys, round: round, spread: spread)] = result
        return result
    }

    /// Deals one round, one position at a time, preferring birds that have not
    /// sung within `gap` positions. When the deck runs short, the bird heard
    /// longest ago wins; a bird heard within `hard` positions is never dealt
    /// while another bird is available.
    private static func deal(keys: [Int], round: Int, lastSeen: inout [Int],
                             gap: Int, hard: Int, firstSlot: [Int]) -> [Int] {
        let count = keys.count
        var state = seed(for: round)
        var remaining = Array(0..<count)
        var result: [Int] = []
        result.reserveCapacity(count)

        for position in 0..<count {
            var pick = -1
            for _ in 0..<32 where !remaining.isEmpty {
                let i = Int(nextRandom(&state) % UInt64(remaining.count))
                if position - lastSeen[keys[remaining[i]]] > gap {
                    pick = i
                    break
                }
            }
            if pick < 0 && !remaining.isEmpty {
                let startAt = Int(nextRandom(&state) % UInt64(remaining.count))
                pick = startAt
                for step in 1..<max(remaining.count, 1) {
                    let i = (startAt + step) % remaining.count
                    if lastSeen[keys[remaining[i]]] < lastSeen[keys[remaining[pick]]] { pick = i }
                }
                if position - lastSeen[keys[remaining[pick]]] <= hard { pick = -1 }
            }

            let slot: Int
            if pick >= 0 {
                slot = remaining[pick]
                remaining.swapAt(pick, remaining.count - 1)
                remaining.removeLast()
            } else {
                // Only recent birds are left in this round: deal the bird heard longest ago instead.
                var bird = 0
                for b in 1..<max(lastSeen.count, 1) where lastSeen[b] < lastSeen[bird] { bird = b }
                slot = firstSlot[bird]
            }
            result.append(slot)
            lastSeen[keys[slot]] = position
        }
        return result
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

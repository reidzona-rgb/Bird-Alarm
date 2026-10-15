import Foundation
import SwiftUI

/// One alarm the user has set: a time of day that rings every day while on.
struct AlarmItem: Codable, Identifiable, Equatable {
    var id: UUID
    var hour: Int
    var minute: Int
    var isEnabled: Bool
}

/// The clock engine.
///
/// For every alarm that is on, it keeps seven system alarms in place, one per
/// weekday, each repeating weekly and each carrying the bird for that
/// weekday's next ring. A "reconcile" step compares what should exist with
/// what the system holds and changes only the difference. It runs at every
/// opportunity: app launch, coming to the foreground, Stop on the lock screen,
/// dismissal, and periodically while the app is on screen. Between alarms the
/// app does nothing at all: it never keeps itself or the phone awake.
///
/// Because the alarms repeat, they can never run out, even if the app is not
/// opened for months. The worst case is a bird repeating after a week.
///
/// State changes happen on the main thread.
final class AlarmStore: ObservableObject {
    static let shared = AlarmStore()

    private enum Key {
        static let alarms = "alarms.list"
        static let legacyHour = "alarm.hour"
        static let legacyMinute = "alarm.minute"
        static let legacyEnabled = "alarm.enabled"
        static let handled = "alarm.handledKeys"
        static let stopped = "alarm.stoppedKeys"
        static let selectedRegions = "deck.selectedRegions"
    }

    /// Opening the app this long after an alarm still shows that ring's bird.
    private static let lateWindow: TimeInterval = 3 * 60 * 60
    /// How often an awake app re-checks the system alarms.
    private static let reconcileInterval: TimeInterval = 5 * 60
    /// For this long after its ring time, an alarm is left exactly as it is
    /// (unless it has been stopped or dismissed), so an update can never cut off
    /// an alarm that has only just started ringing.
    private static let ringGrace: TimeInterval = 15 * 60
    /// Alarms this close to the signature running out carry a re-sign reminder.
    private static let resignNoticeWindow: TimeInterval = 36 * 60 * 60
    /// How many stopped / dismissed rings are remembered.
    private static let rememberedRings = 64

    private static let weekdays: [Locale.Weekday] =
        [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]

    /// One ring of one alarm on one calendar day.
    private struct Fire {
        let alarm: AlarmItem
        let date: Date
        var key: String {
            "\(ShuffleDeck.dayNumber(for: date))|\(alarm.id.uuidString)|\(alarm.hour):\(alarm.minute)"
        }
    }

    private struct WantedAlarm {
        let id: UUID
        let weekday: Locale.Weekday
        let hour: Int
        let minute: Int
        let birdID: String
        let birdName: String
        let title: String
    }

    let library = BirdLibrary.shared
    private let chorus = ChorusPlayer()
    private let defaults = UserDefaults.standard
    private var ticker: Timer?
    private var activeKey: String?
    private var activeFire: Fire?
    private var pendingChange: DispatchWorkItem?
    private var isReconciling = false
    private var reconcileQueued = false
    private var needsReconcile = false
    private var lastReconcile = Date.distantPast

    /// Every alarm the user has set, sorted by time of day.
    @Published private(set) var alarms: [AlarmItem] = AlarmStore.loadAlarms()

    /// Regions the user has chosen to draw from. Empty = all regions.
    @Published var selectedRegions: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: Key.selectedRegions) ?? []
        return Set(saved)
    }() {
        didSet {
            defaults.set(Array(selectedRegions), forKey: Key.selectedRegions)
            if anyEnabled { reconcileSoon() }
        }
    }

    /// Non-nil while the waking screen is up.
    @Published private(set) var activeBird: Bird?
    @Published private(set) var nextFireDate: Date?
    @Published private(set) var isPreview = false
    /// False once the user has refused alarm permission.
    @Published private(set) var alarmsAllowed = true
    /// How many system alarms iOS refused to schedule on the last attempt.
    @Published private(set) var scheduleFailures = 0
    /// When the app's signature runs out, if the app can tell.
    let signatureExpiry: Date? = SigningInfo.expiryDate

    var anyEnabled: Bool { alarms.contains { $0.isEnabled } }

    /// How many system alarms the app keeps in place (seven per alarm that is on).
    var systemAlarmCount: Int { enabledAlarms.count * 7 }

    /// Alarms that are on, in the order their birds are dealt each day.
    private var enabledAlarms: [AlarmItem] {
        alarms.filter { $0.isEnabled }
            .sorted { ($0.hour, $0.minute, $0.id.uuidString) < ($1.hour, $1.minute, $1.id.uuidString) }
    }

    private init() {
        if anyEnabled { enable() }
    }

    // MARK: Editing alarms

    func addAlarm(hour: Int, minute: Int) {
        alarms.append(AlarmItem(id: UUID(), hour: hour, minute: minute, isEnabled: true))
        alarmsChanged()
    }

    func updateAlarm(id: UUID, hour: Int, minute: Int) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[i].hour = hour
        alarms[i].minute = minute
        alarms[i].isEnabled = true
        alarmsChanged()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let i = alarms.firstIndex(where: { $0.id == id }), alarms[i].isEnabled != enabled else { return }
        alarms[i].isEnabled = enabled
        alarmsChanged()
    }

    func deleteAlarm(id: UUID) {
        alarms.removeAll { $0.id == id }
        alarmsChanged()
    }

    /// True if another alarm already rings at this time.
    func hasAlarm(hour: Int, minute: Int, excluding id: UUID? = nil) -> Bool {
        alarms.contains { $0.id != id && $0.hour == hour && $0.minute == minute }
    }

    /// The next time this alarm rings, if it is on.
    func nextFire(of alarm: AlarmItem) -> Date? {
        guard alarm.isEnabled else { return nil }
        return upcomingFire(of: alarm, after: Date())
    }

    private func alarmsChanged() {
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        if let data = try? JSONEncoder().encode(alarms) {
            defaults.set(data, forKey: Key.alarms)
        }
        if anyEnabled {
            startTicker()
            updateNextFireDate()
            reconcileSoon()
        } else {
            disable()
        }
    }

    // MARK: Public actions

    /// Call when the app comes to the foreground or is opened from the alarm.
    func appBecameActive() {
        alarmsAllowed = !SystemAlarm.isDenied
        guard anyEnabled else { return }
        checkDue()
        updateNextFireDate()
        requestReconcile()
    }

    /// Stop was tapped on the system alarm screen: go quiet, keep the bird card
    /// for later, and point this alarm's weekday at next week's bird.
    @MainActor
    func handleSystemStop() async {
        if let fire = currentFires(now: Date(), lead: 5).first {
            remember(fire.key, under: Key.stopped)
        }
        stopChorus()
        // The alarm can still be marked as ringing for a moment after Stop is tapped.
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            needsReconcile = false
            await reconcile()
            if !needsReconcile { break }
        }
    }

    /// Kills the audio and returns to the home view.
    func dismiss() {
        stopChorus()
        if isPreview {
            isPreview = false
            activeBird = nil
            return
        }

        if let handledKey = activeKey {
            remember(handledKey, under: Key.handled)
        }
        SystemAlarm.stopAlerting()
        if let fire = activeFire, fire.date > Date(), let wanted = wantedAlarm(for: fire) {
            // Dismissed during the lead-in: take this alarm off so it does not
            // ring in a minute. Reconcile puts its weekday back once it has passed.
            SystemAlarm.cancel(id: wanted.id)
        }
        activeBird = nil
        activeKey = nil
        activeFire = nil
        needsReconcile = true
        requestReconcile()
    }

    /// Shows the waking screen right now with a random bird, without touching the schedule.
    func preview() {
        guard activeBird == nil, let bird = randomBird() else { return }
        isPreview = true
        activeBird = bird
        startChorus(lead: bird, gentle: true)
    }

    // MARK: Switching on and off

    private func enable() {
        startTicker()
        updateNextFireDate()
        checkDue()
        requestReconcile()
    }

    private func disable() {
        pendingChange?.cancel()
        SystemAlarm.cancelAll()
        if !isPreview { clearCard() }
        nextFireDate = nil
        scheduleFailures = 0
        needsReconcile = false
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: Keeping the system alarms correct

    private func requestReconcile() {
        Task { @MainActor [weak self] in
            await self?.reconcile()
        }
    }

    /// Several quick edits fire many changes; wait for them to settle.
    private func reconcileSoon() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestReconcile() }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Only one reconcile runs at a time. A request that arrives while one is
    /// running makes it go round again, so the last settings always win.
    @MainActor
    func reconcile() async {
        guard anyEnabled else { return }
        if isReconciling {
            reconcileQueued = true
            return
        }
        isReconciling = true
        repeat {
            reconcileQueued = false
            await reconcileOnce()
        } while reconcileQueued && anyEnabled
        isReconciling = false
    }

    @MainActor
    private func reconcileOnce() async {
        lastReconcile = Date()
        let allowed = await SystemAlarm.requestAuthorization()
        alarmsAllowed = allowed
        guard allowed, anyEnabled else { return }

        guard let existing = SystemAlarm.existing() else {
            needsReconcile = true
            return
        }
        // Never touch the alarms while one is ringing; try again shortly.
        if existing.contains(where: { $0.isAlerting }) {
            needsReconcile = true
            return
        }

        let wanted = wantedAlarms(now: Date())
        let existingIDs = Set(existing.map { $0.id })

        // Add what is missing first, then remove what is stale. If the app is
        // killed half-way, the phone is left with an extra alarm, never a missing one.
        var failures = 0
        for alarm in wanted.alarms where !existingIDs.contains(alarm.id) {
            var scheduled = false
            for _ in 0..<3 where !scheduled {
                scheduled = await SystemAlarm.schedule(
                    id: alarm.id, weekday: alarm.weekday, hour: alarm.hour, minute: alarm.minute,
                    title: alarm.title, birdName: alarm.birdName,
                    soundFile: Self.clipName(for: alarm.birdID))
            }
            if !scheduled { failures += 1 }
            if !anyEnabled {
                SystemAlarm.cancelAll()         // switched off while we were working
                return
            }
        }
        if reconcileQueued { return }           // settings changed meanwhile: start over with fresh facts

        let wantedIDs = Set(wanted.alarms.map { $0.id })
        for alarm in existing where !wantedIDs.contains(alarm.id) {
            SystemAlarm.cancel(id: alarm.id)
        }
        scheduleFailures = failures
        needsReconcile = failures > 0 || wanted.deferred
    }

    /// The system alarms that should exist right now: for each alarm that is on
    /// and each weekday, its next ring and the bird for that ring. `deferred` is
    /// true when a ring was dismissed early and its weekday has to wait until the
    /// time has passed.
    private func wantedAlarms(now: Date) -> (alarms: [WantedAlarm], deferred: Bool) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var deferred = false
        var result: [WantedAlarm] = []

        for alarm in enabledAlarms {
            var seenWeekdays = Set<Int>()
            for offset in 0..<8 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                      let date = fireDate(of: alarm, on: day) else { continue }
                let fire = Fire(alarm: alarm, date: date)
                let weekday = calendar.component(.weekday, from: date)      // 1 = Sunday
                if seenWeekdays.contains(weekday) { continue }
                if date <= now {
                    let justRang = now.timeIntervalSince(date) < Self.ringGrace
                        && !isRemembered(fire.key, under: Key.handled)
                        && !isRemembered(fire.key, under: Key.stopped)
                    if !justRang { continue }
                    // Still inside the grace period: keep this alarm untouched.
                }
                seenWeekdays.insert(weekday)
                if isRemembered(fire.key, under: Key.handled) {
                    deferred = true
                    continue
                }
                if let wanted = wantedAlarm(for: fire) { result.append(wanted) }
            }
        }
        return (result, deferred)
    }

    private func wantedAlarm(for fire: Fire) -> WantedAlarm? {
        guard let bird = bird(for: fire) else { return nil }
        let weekday = Calendar.current.component(.weekday, from: fire.date)

        // On the last morning before the signature runs out, say so on the alarm itself.
        var resignDue = false
        if let expiry = signatureExpiry {
            resignDue = fire.date >= expiry.addingTimeInterval(-Self.resignNoticeWindow)
        }
        let title = resignDue ? "\(bird.name) is singing. Re-sign Birdsong today."
                              : "\(bird.name) is singing"

        return WantedAlarm(
            id: SystemAlarm.alarmID(weekday: weekday, hour: fire.alarm.hour, minute: fire.alarm.minute,
                                    birdID: bird.id,
                                    flag: fire.alarm.id.uuidString + (resignDue ? "|resign" : "")),
            weekday: Self.weekdays[(weekday - 1) % 7],
            hour: fire.alarm.hour,
            minute: fire.alarm.minute,
            birdID: bird.id,
            birdName: bird.name,
            title: title)
    }

    // MARK: Time helpers

    /// The alarm moment on a given calendar day, in the phone's current time zone.
    private func fireDate(of alarm: AlarmItem, on day: Date) -> Date? {
        Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: day)
    }

    private func upcomingFire(of alarm: AlarmItem, after now: Date) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        for offset in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let date = fireDate(of: alarm, on: day), date > now else { continue }
            return date
        }
        return nil
    }

    /// Rings whose window we are inside right now, newest first: from `lead`
    /// seconds before each rings until three hours after.
    private func currentFires(now: Date, lead: TimeInterval) -> [Fire] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var found: [Fire] = []
        for alarm in enabledAlarms {
            for offset in [0, 1, -1] {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                      let date = fireDate(of: alarm, on: day) else { continue }
                if now >= date.addingTimeInterval(-lead) && now <= date.addingTimeInterval(Self.lateWindow) {
                    found.append(Fire(alarm: alarm, date: date))
                }
            }
        }
        return found.sorted { $0.date > $1.date }
    }

    private func updateNextFireDate() {
        guard anyEnabled else { return }
        let now = Date()
        let next = enabledAlarms.compactMap { upcomingFire(of: $0, after: now) }.min()
        if next != nextFireDate { nextFireDate = next }
    }

    private func remember(_ key: String, under listKey: String) {
        var list = defaults.stringArray(forKey: listKey) ?? []
        guard !list.contains(key) else { return }
        list.append(key)
        defaults.set(Array(list.suffix(Self.rememberedRings)), forKey: listKey)
    }

    private func isRemembered(_ key: String, under listKey: String) -> Bool {
        defaults.stringArray(forKey: listKey)?.contains(key) ?? false
    }

    // MARK: Birds

    /// Playable birds filtered to selected regions, or all if none selected.
    private var activePool: [Bird] {
        var pool = library.playable
        if pool.isEmpty { pool = library.birds }
        if !selectedRegions.isEmpty {
            let filtered = pool.filter { selectedRegions.contains($0.region) }
            if !filtered.isEmpty { pool = filtered }
        }
        return pool
    }

    /// The pool expanded by harmonic score so high-scoring birds appear more
    /// often (score 10 → 10 slots, score 1 → 1 slot). `keys` names each slot's bird.
    private var activeDeck: (birds: [Bird], keys: [Int]) {
        var birds: [Bird] = []
        var keys: [Int] = []
        for (index, bird) in activePool.enumerated() {
            for _ in 0..<max(1, bird.harmonicScore) {
                birds.append(bird)
                keys.append(index)
            }
        }
        return (birds, keys)
    }

    /// The randomization engine. Every ring of every alarm is one card in a
    /// single endless deal: each day's alarms take consecutive cards in time
    /// order, so they always get different birds, and no bird comes back until
    /// many others have sung. Nothing is stored, so re-installing cannot reset it.
    private func bird(for fire: Fire) -> Bird? {
        let ordered = enabledAlarms
        guard let position = ordered.firstIndex(where: { $0.id == fire.alarm.id }) else { return nil }
        let deck = activeDeck
        guard !deck.birds.isEmpty else { return nil }
        let index = ShuffleDeck.dayNumber(for: fire.date) * ordered.count + position
        let slot = ShuffleDeck.slot(keys: deck.keys, index: index, spread: max(1, ordered.count - 1))
        return deck.birds[slot]
    }

    /// A plain weighted random draw, used only for the preview button.
    private func randomBird() -> Bird? {
        activeDeck.birds.randomElement()
    }

    /// The system alarm can only play a short clip stored at the root of the app bundle.
    private static func clipName(for birdID: String) -> String? {
        let name = "birdsong_\(birdID)"
        guard Bundle.main.url(forResource: name, withExtension: "caf") != nil else { return nil }
        return name + ".caf"
    }

    // MARK: Waking screen

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        checkDue()
        updateNextFireDate()
        let wait = needsReconcile ? 5 : Self.reconcileInterval
        if Date().timeIntervalSince(lastReconcile) > wait {
            lastReconcile = Date()
            requestReconcile()
        }
    }

    /// Shows the waking screen when an alarm's window opens, and takes it down
    /// again when the window closes, so a stale card never lingers. A newer
    /// alarm takes over from an older one.
    private func checkDue() {
        guard anyEnabled else { return }
        guard let fire = currentFires(now: Date(), lead: 0).first else {
            // A silent, forgotten card expires with its ring. A chorus that is
            // still playing is never cut off: only the owner ends it.
            if activeKey != nil && !chorus.isChorusPlaying { clearCard() }
            return
        }
        let fireKey = fire.key
        if fireKey == activeKey || isRemembered(fireKey, under: Key.handled) { return }
        ring(fire)
    }

    private func ring(_ fire: Fire) {
        guard let bird = bird(for: fire) else { return }
        stopChorus()
        isPreview = false                       // a real alarm outranks a preview
        activeKey = fire.key
        activeFire = fire
        activeBird = bird

        // If Stop was already tapped on the lock screen, show the card without sound.
        if !isRemembered(fire.key, under: Key.stopped) {
            // On screen at the alarm moment: the full one-minute dawn build.
            // Opened afterwards: take over from the system alarm at an audible level.
            let onTheDot = Date().timeIntervalSince(fire.date) < 10
            startChorus(lead: bird, gentle: onTheDot)
        }
    }

    private func clearCard() {
        stopChorus()
        activeKey = nil
        activeFire = nil
        activeBird = nil
    }

    /// The chorus has no time limit. It plays until the alarm is dismissed in
    /// the app or stopped from the lock screen.
    private func startChorus(lead: Bird, gentle: Bool) {
        let companions = activePool.filter { $0.id != lead.id }.shuffled()
        chorus.startChorus(lead: lead, companions: Array(companions.prefix(2)), gentle: gentle)
    }

    private func stopChorus() {
        chorus.stopChorus()
    }

    // MARK: Helpers

    /// Saved alarms, or the single alarm from before multiple alarms existed.
    private static func loadAlarms() -> [AlarmItem] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Key.alarms),
           let saved = try? JSONDecoder().decode([AlarmItem].self, from: data) {
            return saved.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        }
        let legacy = AlarmItem(
            id: UUID(),
            hour: defaults.object(forKey: Key.legacyHour) as? Int ?? 7,
            minute: defaults.object(forKey: Key.legacyMinute) as? Int ?? 0,
            isEnabled: defaults.bool(forKey: Key.legacyEnabled))
        if let data = try? JSONEncoder().encode([legacy]) {
            defaults.set(data, forKey: Key.alarms)
        }
        return [legacy]
    }
}

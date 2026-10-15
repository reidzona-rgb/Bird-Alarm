import Foundation
import SwiftUI

/// The clock engine.
///
/// It keeps seven system alarms in place, one per weekday, each repeating
/// weekly and each carrying the bird for that weekday's next morning. A
/// "reconcile" step compares what should exist with what the system holds and
/// changes only the difference. It runs at every opportunity: app launch,
/// coming to the foreground, Stop on the lock screen, dismissal, and
/// periodically while the app is on screen. Between alarms the app does
/// nothing at all: it never keeps itself or the phone awake.
///
/// Because the alarms repeat, they can never run out, even if the app is not
/// opened for months. The worst case is a bird repeating after a week.
///
/// State changes happen on the main thread.
final class AlarmStore: ObservableObject {
    static let shared = AlarmStore()

    private enum Key {
        static let hour = "alarm.hour"
        static let minute = "alarm.minute"
        static let enabled = "alarm.enabled"
        static let handled = "alarm.handledKey"
        static let stopped = "alarm.stoppedKey"
        static let selectedRegions = "deck.selectedRegions"
    }

    /// Opening the app this long after an alarm still shows that morning's bird.
    private static let lateWindow: TimeInterval = 3 * 60 * 60
    /// How often an awake app re-checks the system alarms.
    private static let reconcileInterval: TimeInterval = 5 * 60
    /// For this long after its ring time, today's alarm is left exactly as it is
    /// (unless it has been stopped or dismissed), so an update can never cut off
    /// an alarm that has only just started ringing.
    private static let ringGrace: TimeInterval = 15 * 60
    /// Alarms this close to the signature running out carry a re-sign reminder.
    private static let resignNoticeWindow: TimeInterval = 36 * 60 * 60

    private static let weekdays: [Locale.Weekday] =
        [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]

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
    private var activeFire: Date?
    private var pendingTimeChange: DispatchWorkItem?
    private var isReconciling = false
    private var reconcileQueued = false
    private var needsReconcile = false
    private var lastReconcile = Date.distantPast

    @Published var time: Date = AlarmStore.storedTime() {
        didSet {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            defaults.set(parts.hour ?? 7, forKey: Key.hour)
            defaults.set(parts.minute ?? 0, forKey: Key.minute)
            if activeKey != nil { clearCard() }
            updateNextFireDate()
            if isEnabled { reconcileSoon() }
        }
    }

    /// Regions the user has chosen to draw from. Empty = all regions.
    @Published var selectedRegions: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: Key.selectedRegions) ?? []
        return Set(saved)
    }() {
        didSet {
            defaults.set(Array(selectedRegions), forKey: Key.selectedRegions)
            if isEnabled { reconcileSoon() }
        }
    }

    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: Key.enabled) {
        didSet {
            defaults.set(isEnabled, forKey: Key.enabled)
            if isEnabled { enable() } else { disable() }
        }
    }

    /// Non-nil while the waking screen is up.
    @Published private(set) var activeBird: Bird?
    @Published private(set) var nextFireDate: Date?
    @Published private(set) var isPreview = false
    /// False once the user has refused alarm permission.
    @Published private(set) var alarmsAllowed = true
    /// How many weekday alarms the system refused to schedule on the last attempt.
    @Published private(set) var scheduleFailures = 0
    /// When the app's signature runs out, if the app can tell.
    let signatureExpiry: Date? = SigningInfo.expiryDate

    private init() {
        if isEnabled { enable() }
    }

    // MARK: Public actions

    /// Call when the app comes to the foreground or is opened from the alarm.
    func appBecameActive() {
        alarmsAllowed = !SystemAlarm.isDenied
        guard isEnabled else { return }
        checkDue()
        updateNextFireDate()
        requestReconcile()
    }

    /// Stop was tapped on the system alarm screen: go quiet, keep the bird card
    /// for later, and point this weekday's alarm at next week's bird.
    @MainActor
    func handleSystemStop() async {
        if let fire = currentFire(now: Date(), lead: 5) {
            defaults.set(key(for: fire), forKey: Key.stopped)
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
            defaults.set(handledKey, forKey: Key.handled)
        }
        SystemAlarm.stopAlerting()
        if let fire = activeFire, fire > Date(), let today = wantedAlarm(for: fire) {
            // Dismissed during the lead-in: take today's alarm off so it does not
            // ring in a minute. Reconcile puts this weekday back once it has passed.
            SystemAlarm.cancel(id: today.id)
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
        pendingTimeChange?.cancel()
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

    /// Spinning the time wheel fires many changes; wait for it to settle.
    private func reconcileSoon() {
        pendingTimeChange?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestReconcile() }
        pendingTimeChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Only one reconcile runs at a time. A request that arrives while one is
    /// running makes it go round again, so the last settings always win.
    @MainActor
    func reconcile() async {
        guard isEnabled else { return }
        if isReconciling {
            reconcileQueued = true
            return
        }
        isReconciling = true
        repeat {
            reconcileQueued = false
            await reconcileOnce()
        } while reconcileQueued && isEnabled
        isReconciling = false
    }

    @MainActor
    private func reconcileOnce() async {
        lastReconcile = Date()
        let allowed = await SystemAlarm.requestAuthorization()
        alarmsAllowed = allowed
        guard allowed, isEnabled else { return }

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
            if !isEnabled {
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

    /// The seven alarms that should exist right now: for each weekday, its next
    /// ring and the bird for that date. `deferred` is true when today's alarm was
    /// dismissed early and its weekday has to wait until the time has passed.
    private func wantedAlarms(now: Date) -> (alarms: [WantedAlarm], deferred: Bool) {
        let calendar = Calendar.current
        let handled = defaults.string(forKey: Key.handled)
        let stopped = defaults.string(forKey: Key.stopped)
        let today = calendar.startOfDay(for: now)
        var seenWeekdays = Set<Int>()
        var deferred = false
        var result: [WantedAlarm] = []

        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = fireDate(on: day) else { continue }
            let weekday = calendar.component(.weekday, from: fire)      // 1 = Sunday
            if seenWeekdays.contains(weekday) { continue }
            if fire <= now {
                let fireKey = key(for: fire)
                let justRang = now.timeIntervalSince(fire) < Self.ringGrace
                    && fireKey != handled && fireKey != stopped
                if !justRang { continue }
                // Still inside the grace period: keep today's alarm untouched.
            }
            seenWeekdays.insert(weekday)
            if key(for: fire) == handled {
                deferred = true
                continue
            }
            if let alarm = wantedAlarm(for: fire) { result.append(alarm) }
        }
        return (result, deferred)
    }

    private func wantedAlarm(for fire: Date) -> WantedAlarm? {
        guard let bird = bird(for: fire) else { return nil }
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: fire)
        let parts = alarmTime

        // On the last morning before the signature runs out, say so on the alarm itself.
        var resignDue = false
        if let expiry = signatureExpiry {
            resignDue = fire >= expiry.addingTimeInterval(-Self.resignNoticeWindow)
        }
        let title = resignDue ? "\(bird.name) is singing. Re-sign Birdsong today."
                              : "\(bird.name) is singing"

        return WantedAlarm(
            id: SystemAlarm.alarmID(weekday: weekday, hour: parts.hour, minute: parts.minute,
                                    birdID: bird.id, flag: resignDue ? "resign" : ""),
            weekday: Self.weekdays[(weekday - 1) % 7],
            hour: parts.hour,
            minute: parts.minute,
            birdID: bird.id,
            birdName: bird.name,
            title: title)
    }

    // MARK: Time helpers

    private var alarmTime: (hour: Int, minute: Int) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 7, parts.minute ?? 0)
    }

    /// The alarm moment on a given calendar day, in the phone's current time zone.
    private func fireDate(on day: Date) -> Date? {
        let parts = alarmTime
        return Calendar.current.date(bySettingHour: parts.hour, minute: parts.minute, second: 0, of: day)
    }

    /// Identifies one morning's alarm: the calendar day plus the alarm time.
    private func key(for fire: Date) -> String {
        let parts = alarmTime
        return "\(ShuffleDeck.dayNumber(for: fire))|\(parts.hour):\(parts.minute)"
    }

    /// The alarm whose window we are inside right now: from `lead` seconds
    /// before it rings until three hours after.
    private func currentFire(now: Date, lead: TimeInterval) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        for offset in [0, 1, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = fireDate(on: day) else { continue }
            if now >= fire.addingTimeInterval(-lead) && now <= fire.addingTimeInterval(Self.lateWindow) {
                return fire
            }
        }
        return nil
    }

    private func updateNextFireDate() {
        guard isEnabled else { return }
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        var next: Date?
        for offset in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = fireDate(on: day), fire > now else { continue }
            next = fire
            break
        }
        if next != nextFireDate { nextFireDate = next }
    }

    // MARK: Birds

    /// Playable birds filtered to selected regions, or all if none selected.
    private var activeDeck: [Bird] {
        var pool = library.playable
        if pool.isEmpty { pool = library.birds }
        if !selectedRegions.isEmpty {
            let filtered = pool.filter { selectedRegions.contains($0.region) }
            if !filtered.isEmpty { pool = filtered }
        }
        // Expand pool by harmonic score so high-scoring birds appear more often.
        // Score 10 → 10 slots, score 1 → 1 slot.
        return pool.flatMap { bird in Array(repeating: bird, count: max(1, bird.harmonicScore)) }
    }

    /// The randomization engine. Each morning's bird comes from the shuffled
    /// deck for that calendar date: all birds sing once before any repeats,
    /// and nothing is stored, so re-installing the app cannot reset it.
    private func bird(for date: Date) -> Bird? {
        let pool = activeDeck
        guard !pool.isEmpty else { return nil }
        let day = ShuffleDeck.dayNumber(for: date)
        return pool[ShuffleDeck.slot(count: pool.count, day: day)]
    }

    /// A plain random draw, used only for the preview button.
    private func randomBird() -> Bird? {
        activeDeck.randomElement()
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

    /// Shows the waking screen when the alarm's window opens, and takes it
    /// down again when the window closes, so a stale card never lingers.
    private func checkDue() {
        guard isEnabled else { return }
        guard let fire = currentFire(now: Date(), lead: 0) else {
            // A silent, forgotten card expires with its morning. A chorus that is
            // still playing is never cut off: only the owner ends it.
            if activeKey != nil && !chorus.isChorusPlaying { clearCard() }
            return
        }
        let fireKey = key(for: fire)
        if fireKey == activeKey || fireKey == defaults.string(forKey: Key.handled) { return }
        ring(fire: fire, key: fireKey)
    }

    private func ring(fire: Date, key: String) {
        guard let bird = bird(for: fire) else { return }
        stopChorus()
        isPreview = false                       // a real alarm outranks a preview
        activeKey = key
        activeFire = fire
        activeBird = bird

        // If Stop was already tapped on the lock screen, show the card without sound.
        if defaults.string(forKey: Key.stopped) != key {
            // On screen at the alarm moment: the full one-minute dawn build.
            // Opened afterwards: take over from the system alarm at an audible level.
            let onTheDot = Date().timeIntervalSince(fire) < 10
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
        let pool = activeDeck
        let companions = pool.filter { $0.id != lead.id }.shuffled()
        chorus.startChorus(lead: lead, companions: Array(companions.prefix(2)), gentle: gentle)
    }

    private func stopChorus() {
        chorus.stopChorus()
    }

    // MARK: Helpers

    private static func storedTime() -> Date {
        let defaults = UserDefaults.standard
        let hour = defaults.object(forKey: Key.hour) as? Int ?? 7
        let minute = defaults.object(forKey: Key.minute) as? Int ?? 0
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}

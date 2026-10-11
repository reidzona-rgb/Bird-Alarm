import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI

/// Thin wrapper around AlarmKit (iOS 26). An AlarmKit alarm is a real system
/// alarm: it rings on a locked phone, in Silent mode, through a Focus, and
/// even if this app has been closed.
struct BirdAlarmMetadata: AlarmMetadata {
    var birdName: String
}

/// What the app needs to know about an alarm the system is holding.
struct ExistingAlarm {
    let id: UUID
    let isAlerting: Bool
}

enum SystemAlarm {
    static var isDenied: Bool {
        AlarmManager.shared.authorizationState == .denied
    }

    /// Shows the system permission prompt the first time; afterwards just reports the answer.
    static func requestAuthorization() async -> Bool {
        do {
            return try await AlarmManager.shared.requestAuthorization() == .authorized
        } catch {
            return false
        }
    }

    /// Schedules an alarm that repeats every week on one weekday, at a time of
    /// day. Because it is a time of day and not a fixed moment, iOS keeps it
    /// right across time zones and clock changes, and it never runs out.
    /// `soundFile` is a file name with extension at the root of the app bundle;
    /// nil uses the standard alarm sound.
    static func schedule(id: UUID, weekday: Locale.Weekday, hour: Int, minute: Int,
                         title: String, birdName: String, soundFile: String?) async -> Bool {
        let alertTitle: LocalizedStringResource = "\(title)"
        let stopButton = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
        let openButton = AlarmButton(text: "Meet the bird", textColor: .black, systemImageName: "bird.fill")

        let alert = AlarmPresentation.Alert(
            title: alertTitle,
            stopButton: stopButton,
            secondaryButton: openButton,
            secondaryButtonBehavior: .custom)

        let attributes = AlarmAttributes<BirdAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: BirdAlarmMetadata(birdName: birdName),
            tintColor: Color.yellow)

        let sound: AlertConfiguration.AlertSound
        if let soundFile {
            sound = AlertConfiguration.AlertSound.named(soundFile)
        } else {
            sound = AlertConfiguration.AlertSound.default
        }

        let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
        let schedule = Alarm.Schedule.relative(
            Alarm.Schedule.Relative(time: time, repeats: .weekly([weekday])))

        let configuration = AlarmManager.AlarmConfiguration<BirdAlarmMetadata>.alarm(
            schedule: schedule,
            attributes: attributes,
            stopIntent: StopBirdAlarmIntent(alarmID: id.uuidString),
            secondaryIntent: OpenBirdAlarmIntent(alarmID: id.uuidString),
            sound: sound)

        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    /// Every alarm the system holds for this app, or nil if the list could not be read.
    static func existing() -> [ExistingAlarm]? {
        guard let alarms = try? AlarmManager.shared.alarms else { return nil }
        return alarms.map { alarm in
            var alerting = false
            if case .alerting = alarm.state { alerting = true }
            return ExistingAlarm(id: alarm.id, isAlerting: alerting)
        }
    }

    static func cancel(id: UUID) {
        try? AlarmManager.shared.cancel(id: id)
    }

    /// Silences whichever alarm is ringing right now. It stays scheduled for next week.
    static func stopAlerting() {
        for alarm in existing() ?? [] where alarm.isAlerting {
            try? AlarmManager.shared.stop(id: alarm.id)
        }
    }

    static func cancelAll() {
        for alarm in existing() ?? [] {
            try? AlarmManager.shared.cancel(id: alarm.id)
        }
    }

    /// The same inputs always give the same ID, so the app can tell which of
    /// the alarms it wants are already in place and leave those untouched.
    static func alarmID(weekday: Int, hour: Int, minute: Int, birdID: String, flag: String) -> UUID {
        let text = "\(weekday)|\(hour)|\(minute)|\(birdID)|\(flag)"
        func hash(_ seed: UInt64) -> UInt64 {       // FNV-1a
            var value = seed
            for byte in text.utf8 {
                value ^= UInt64(byte)
                value = value &* 0x100000001B3
            }
            return value
        }
        let high = hash(0xCBF29CE484222325)
        let low = hash(0x84222325CBF29CE4)
        var b: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) { b.append(UInt8((high >> UInt64(shift)) & 0xFF)) }
        for shift in stride(from: 56, through: 0, by: -8) { b.append(UInt8((low >> UInt64(shift)) & 0xFF)) }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// When the app's signature runs out. Apps installed with a free Apple ID
/// stop opening after 7 days until they are re-signed.
enum SigningInfo {
    static let expiryDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>ExpirationDate</key>"),
              let open = text.range(of: "<date>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</date>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return ISO8601DateFormatter().date(from: String(text[open.upperBound..<close.lowerBound]))
    }()
}

/// Runs when Stop is tapped on the system alarm screen.
struct StopBirdAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Birdsong Alarm"

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        // Also the app's daily chance to line up next week's bird for this weekday.
        await AlarmStore.shared.handleSystemStop()
        return .result()
    }
}

/// Runs when "Meet the bird" is tapped. Brings the app forward on the bird card.
struct OpenBirdAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Meet the Bird"
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AlarmStore.shared.appBecameActive()
        }
        return .result()
    }
}

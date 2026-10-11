import SwiftUI

/// The setup state: alarm time, switches, and the before-bed checklist.
struct HomeView: View {
    @EnvironmentObject private var store: AlarmStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    DatePicker("Alarm time", selection: $store.time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()

                    Toggle("Alarm", isOn: $store.isEnabled)
                        .padding(16)
                        .tint(.dawnYellow)
                    .background(Color.cardGray)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let warning = warningText {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.dawnYellow)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    checklist

                    Button("Preview waking screen") { store.preview() }
                        .font(.headline)
                        .foregroundColor(.dawnYellow)
                        .padding(.top, 4)
                }
                .padding(20)
            }
            .navigationTitle("Birdsong")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink("Deck") { DeckView() }
                }
            }
        }
    }

    private var statusText: String {
        guard store.isEnabled, let fire = store.nextFireDate else {
            return "Alarm is off."
        }
        let when = fire.formatted(.dateTime.weekday(.wide).hour().minute())
        var text = "Next alarm: \(when). The bird is a surprise."
        if let expiry = store.signatureExpiry {
            text += " App signature is good until \(expiry.formatted(.dateTime.weekday(.wide).hour().minute()))."
        }
        return text
    }

    private var warningText: String? {
        if !store.alarmsAllowed {
            return "Alarms are switched off for Birdsong. Turn them on in Settings > Apps > Birdsong, or nothing will ring."
        }
        if let expiry = store.signatureExpiry, expiry.timeIntervalSinceNow < 2 * 24 * 60 * 60 {
            let when = expiry.formatted(.dateTime.weekday(.wide).hour().minute())
            return expiry < Date()
                ? "The app's signature has run out. Re-sign it from the PC now."
                : "Re-sign the app from the PC before \(when), or it will stop opening."
        }
        if store.scheduleFailures > 0 {
            return "iOS refused \(store.scheduleFailures) of the 7 weekday alarms. The app keeps retrying while it is open."
        }
        if store.library.playable.isEmpty {
            return "No recordings in the deck. The alarm will ring with the standard iPhone alarm sound."
        }
        return nil
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Good to know")
                .font(.headline)
            ForEach(tips, id: \.self) { tip in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.dawnYellow)
                    Text(tip)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardGray)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var tips: [String] {
        [
            "The alarm rings when the phone is locked, on Silent, in a Focus, and even if this app is closed.",
            "The birdsong keeps going until you tap Stop or Dismiss Alarm.",
            "Nothing runs overnight. The app does not keep the phone awake or use battery between alarms.",
            "Volume follows the iPhone's ringer and alerts slider (Settings > Sounds & Haptics).",
            "Travelling is fine: the alarm follows the phone's local time.",
            "Re-sign the app from the PC once a week. The last alarm before the deadline says so on screen."
        ]
    }
}

/// The Chorus Deck: all 20 slots and whether each has its files.
struct DeckView: View {
    @EnvironmentObject private var store: AlarmStore

    var body: some View {
        List(store.library.birds) { bird in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bird.name).font(.headline)
                    if let latin = bird.scientificName {
                        Text(latin).font(.caption.italic()).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: bird.audioURL != nil ? "waveform" : "speaker.slash")
                    .foregroundColor(bird.audioURL != nil ? .dawnYellow : .secondary)
                Image(systemName: "photo")
                    .foregroundColor(bird.imageURL != nil ? .dawnYellow : .secondary)
            }
        }
        .navigationTitle("Chorus Deck (\(store.library.birds.count))")
        .navigationBarTitleDisplayMode(.inline)
    }
}

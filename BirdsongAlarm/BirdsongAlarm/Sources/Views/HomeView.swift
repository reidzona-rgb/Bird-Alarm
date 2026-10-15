import SwiftUI

/// What the alarm editor sheet is working on.
private enum EditorTarget: Identifiable {
    case new
    case edit(AlarmItem)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let alarm): return alarm.id.uuidString
        }
    }
}

/// The setup state: the list of alarms and their switches.
struct HomeView: View {
    @EnvironmentObject private var store: AlarmStore
    @State private var editor: EditorTarget?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if store.alarms.isEmpty {
                        Text("No alarms. Tap + to add one.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }

                    ForEach(store.alarms) { alarm in
                        AlarmRow(alarm: alarm) { editor = .edit(alarm) }
                    }

                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }

                    if let warning = warningText {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.dawnYellow)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button("Preview waking screen") { store.preview() }
                        .font(.headline)
                        .foregroundColor(.dawnYellow)
                        .padding(.top, 10)
                }
                .padding(20)
            }
            .navigationTitle("Birdsong")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink("Deck") { DeckView() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { editor = .new } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add alarm")
                }
            }
            .tint(.dawnYellow)
            .sheet(item: $editor) { target in
                Group {
                    switch target {
                    case .new: AlarmEditor(alarm: nil)
                    case .edit(let alarm): AlarmEditor(alarm: alarm)
                    }
                }
                .environmentObject(store)
            }
        }
    }

    private var statusText: String {
        guard store.anyEnabled, let fire = store.nextFireDate else {
            return store.alarms.isEmpty ? "" : "All alarms are off."
        }
        let when = fire.formatted(.dateTime.weekday(.wide).hour().minute())
        var text = "Next alarm: \(when). Every alarm brings a different bird."
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
            return "iOS refused \(store.scheduleFailures) of the \(store.systemAlarmCount) scheduled alarms. The app keeps retrying while it is open."
        }
        if store.library.playable.isEmpty {
            return "No recordings in the deck. The alarm will ring with the standard iPhone alarm sound."
        }
        return nil
    }
}

private func timeText(hour: Int, minute: Int) -> String {
    let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    return date.formatted(date: .omitted, time: .shortened)
}

/// One alarm in the list: tap the time to edit, flip the switch to turn it on or off.
private struct AlarmRow: View {
    @EnvironmentObject private var store: AlarmStore
    let alarm: AlarmItem
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeText(hour: alarm.hour, minute: alarm.minute))
                        .font(.system(size: 44, weight: .light, design: .rounded))
                        .foregroundColor(alarm.isEnabled ? .white : .secondary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("Alarm \(timeText(hour: alarm.hour, minute: alarm.minute))", isOn: Binding(
                get: { alarm.isEnabled },
                set: { store.setEnabled($0, for: alarm.id) }))
                .labelsHidden()
                .tint(.dawnYellow)
        }
        .padding(16)
        .background(Color.cardGray)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var subtitle: String {
        guard let next = store.nextFire(of: alarm) else { return "Off" }
        return "Every day · next " + next.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Sheet for adding a new alarm or changing / deleting an existing one.
private struct AlarmEditor: View {
    @EnvironmentObject private var store: AlarmStore
    @Environment(\.dismiss) private var dismiss
    let alarm: AlarmItem?
    @State private var time: Date

    init(alarm: AlarmItem?) {
        self.alarm = alarm
        let hour = alarm?.hour ?? 7
        let minute = alarm?.minute ?? 0
        _time = State(initialValue: Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date())
    }

    private var parts: (hour: Int, minute: Int) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (c.hour ?? 7, c.minute ?? 0)
    }

    private var isDuplicate: Bool {
        store.hasAlarm(hour: parts.hour, minute: parts.minute, excluding: alarm?.id)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker("Alarm time", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()

                if isDuplicate {
                    Text("You already have an alarm at this time.")
                        .font(.footnote)
                        .foregroundColor(.dawnYellow)
                }

                if let alarm {
                    Button(role: .destructive) {
                        store.deleteAlarm(id: alarm.id)
                        dismiss()
                    } label: {
                        Text("Delete Alarm")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.cardGray)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle(alarm == nil ? "Add Alarm" : "Edit Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let alarm {
                            store.updateAlarm(id: alarm.id, hour: parts.hour, minute: parts.minute)
                        } else {
                            store.addAlarm(hour: parts.hour, minute: parts.minute)
                        }
                        dismiss()
                    }
                    .disabled(isDuplicate)
                }
            }
        }
        .tint(.dawnYellow)
        .presentationDetents([.medium, .large])
    }
}

/// Chorus Deck with two sub-tabs: bird list and region selector.
struct DeckView: View {
    @EnvironmentObject private var store: AlarmStore
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Birds").tag(0)
                Text("Regions").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if tab == 0 {
                BirdListView()
            } else {
                RegionSelectView()
            }
        }
        .navigationTitle("Chorus Deck")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BirdListView: View {
    @EnvironmentObject private var store: AlarmStore

    var body: some View {
        List(store.library.birds) { bird in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bird.name).font(.headline)
                    if let latin = bird.scientificName {
                        Text(latin).font(.caption.italic()).foregroundColor(.secondary)
                    }
                    Text(regionLabel(bird.region))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                // Harmonic score dots
                HStack(spacing: 2) {
                    ForEach(0..<5) { i in
                        Circle()
                            .frame(width: 5, height: 5)
                            .foregroundColor(bird.harmonicScore >= (i * 2 + 2) ? .dawnYellow : Color.white.opacity(0.15))
                    }
                }
                .padding(.trailing, 6)
                Image(systemName: bird.audioURL != nil ? "waveform" : "speaker.slash")
                    .foregroundColor(bird.audioURL != nil ? .dawnYellow : .secondary)
                Image(systemName: "photo")
                    .foregroundColor(bird.imageURL != nil ? .dawnYellow : .secondary)
            }
        }
        .listStyle(.plain)
        .overlay(alignment: .bottom) {
            Text("\(store.library.birds.count) birds · \(store.library.playable.count) with audio")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 6)
        }
    }

    private func regionLabel(_ id: String) -> String {
        allRegions.first { $0.id == id }?.label ?? id
    }
}

import AVFoundation
import Foundation

/// Plays the layered dawn chorus inside the app.
///
/// It only ever makes sound while an alarm is being answered. Nothing here
/// runs in the background between alarms, so the app does not keep the phone
/// awake. Once started, the chorus loops until `stopChorus()` is called.
final class ChorusPlayer {
    /// One voice in the chorus: when it enters and how it swells.
    private struct Voice {
        let delay: TimeInterval
        let startVolume: Float
        let endVolume: Float
        let fade: TimeInterval
    }

    /// The full dawn build: the day's bird swells for a minute, and two
    /// companions join at 20 and 40 seconds.
    private static let gentleBuild: [Voice] = [
        Voice(delay: 0, startVolume: 0.03, endVolume: 0.85, fade: 60),
        Voice(delay: 20, startVolume: 0.0, endVolume: 0.45, fade: 40),
        Voice(delay: 40, startVolume: 0.0, endVolume: 0.35, fade: 20)
    ]

    /// Taking over from a system alarm that was already ringing: come in at a
    /// clearly audible level so the birdsong never seems to have stopped.
    private static let handover: [Voice] = [
        Voice(delay: 0, startVolume: 0.5, endVolume: 0.85, fade: 6),
        Voice(delay: 4, startVolume: 0.0, endVolume: 0.45, fade: 6),
        Voice(delay: 8, startVolume: 0.0, endVolume: 0.35, fade: 6)
    ]

    private var layers: [AVAudioPlayer] = []
    private var pending: [DispatchWorkItem] = []

    private(set) var isChorusPlaying = false

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Starts the layered chorus. It loops until `stopChorus()`.
    /// Returns false if no recording could be played.
    @discardableResult
    func startChorus(lead: Bird, companions: [Bird], gentle: Bool) -> Bool {
        stopChorus()
        activateSession()

        let voices = gentle ? Self.gentleBuild : Self.handover
        let lineup = [lead] + companions.prefix(voices.count - 1)
        for (index, bird) in lineup.enumerated() {
            guard let url = bird.audioURL,
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            let voice = voices[index]
            player.numberOfLoops = -1               // loop for as long as it takes
            player.volume = voice.startVolume
            player.prepareToPlay()
            layers.append(player)

            let work = DispatchWorkItem { [weak player] in
                player?.play()
                player?.setVolume(voice.endVolume, fadeDuration: voice.fade)
            }
            if voice.delay == 0 {
                work.perform()
            } else {
                pending.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + voice.delay, execute: work)
            }
        }
        isChorusPlaying = !layers.isEmpty
        return isChorusPlaying
    }

    func stopChorus() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
        layers.forEach { $0.stop() }
        layers.removeAll()
        isChorusPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: Audio session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        // .playback ignores the Ring/Silent switch and lets a chorus that is
        // already playing carry on if the screen locks before it is dismissed.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard isChorusPlaying,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .ended else { return }
        // A phone call or Siri paused the chorus. It has not been dismissed, so pick back up.
        try? AVAudioSession.sharedInstance().setActive(true)
        layers.forEach { $0.play() }
    }
}

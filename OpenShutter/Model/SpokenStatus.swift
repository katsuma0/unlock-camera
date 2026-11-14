import AVFoundation
import UIKit

/// Says the countdown and when a long shot starts and ends, for someone who isn't looking at the screen: the phone on
/// a tripod across the room, or the person in the picture. Speech mixes with other sound and stays out of the
/// capture session's audio (usesApplicationAudioSession off). While VoiceOver runs the line goes to VoiceOver
/// instead, so nothing is said twice. The model decides what to say and when (never while filming).
@MainActor
final class SpokenStatus {
    /// Made at the first line, so a person who never turns the setting on never loads a speech engine.
    private var synthesizer: AVSpeechSynthesizer?

    func say(_ text: String) {
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
            return
        }
        let synthesizer = self.synthesizer ?? makeSynthesizer()
        // The newest line wins: a countdown that fell behind would still be counting once the shot has started.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        // The voice and speed the person picked for Spoken Content.
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
    }

    func stop() {
        guard let synthesizer, synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func makeSynthesizer() -> AVSpeechSynthesizer {
        let made = AVSpeechSynthesizer()
        // Its own audio session, which ducks music and leaves the camera's alone.
        made.usesApplicationAudioSession = false
        synthesizer = made
        return made
    }
}

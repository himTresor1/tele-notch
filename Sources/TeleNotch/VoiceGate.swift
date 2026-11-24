import AVFAudio
import Foundation

/// Keeps only the voice close to the mic: yours.
///
/// Someone across the room (or office chatter, an air conditioner) reaches the mic 10–20 dB quieter than
/// the person sitting at the Mac. The gate learns how loud you are when you speak and mutes anything well
/// below that, so a colleague who's in the same meeting isn't transcribed twice (once garbled through the
/// room, once clearly through the call), and background noise doesn't turn into made-up words.
/// Muted audio is replaced with silence rather than dropped, so the speech model keeps its timing.
final class VoiceGate: @unchecked Sendable {
    /// How far below your speaking level a sound can be and still count as you.
    var range: Float = 12
    private let lock = NSLock()
    private var speech: Float = -30      // your recent speaking level, dBFS
    private var floor: Float = -60       // background noise level, dBFS
    private var openUntil: Double = 0    // keep the gate open briefly so word endings aren't clipped
    private var clock: Double = 0
    private(set) var passed = 0, muted = 0

    func reset() { lock.lock(); speech = -30; floor = -60; openUntil = 0; clock = 0; passed = 0; muted = 0; lock.unlock() }

    /// Mutes `buffer` in place when it's background, and returns it.
    @discardableResult
    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return buffer }
        // Interleaved audio is one run of frames × channels; otherwise one run per channel.
        let interleaved = buffer.format.isInterleaved
        let chans = interleaved ? 1 : Int(buffer.format.channelCount)
        let n = Int(buffer.frameLength) * (interleaved ? Int(buffer.format.channelCount) : 1)
        var sum: Float = 0
        for c in 0..<chans { let p = ch[c]; for i in 0..<n { sum += p[i] * p[i] } }
        let level = 10 * log10(max(sum / Float(n * chans), 1e-12))   // dBFS
        let dt = Double(buffer.frameLength) / buffer.format.sampleRate

        lock.lock()
        clock += dt
        // Background: follows quiet moments quickly, rises slowly.
        floor = level < floor ? floor + (level - floor) * 0.3 : floor + Float(dt) * 0.5
        // Your voice: jumps up to loud speech, drifts down slowly so a softer voice is learned too.
        if level > floor + 10 {
            speech = level > speech ? speech + (level - speech) * 0.5 : speech - Float(dt) * 0.3
        }
        speech = min(max(speech, -45), 0)
        let threshold = max(speech - range, floor + 6)
        if level >= threshold { openUntil = clock + 0.35 }
        let open = clock <= openUntil
        if open { passed += 1 } else { muted += 1 }
        lock.unlock()

        if !open { for c in 0..<chans { ch[c].update(repeating: 0, count: n) } }
        return buffer
    }
}

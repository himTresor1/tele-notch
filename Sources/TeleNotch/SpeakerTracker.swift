import AVFAudio
import FluidAudio
import Foundation

/// Tells the "Others" voices apart by sound, on this Mac.
///
/// Everyone else in a call reaches TeleNotch as one mixed audio stream. This runs FluidAudio's streaming
/// Sortformer diarization model on that stream (on-device, up to 4 voices, about a second behind) and keeps
/// a timeline of which voice spoke when. Each "Others" transcript line then gets the voice that spoke most
/// during it. The model is downloaded once (from Hugging Face) the first time; audio never leaves the Mac.
final class SpeakerTracker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "telenotch.speakers", qos: .utility)
    private var diarizer: (any Diarizer)?
    private var loading = false
    /// Seconds of "Others" audio seen so far. Matches the transcriber's audio clock, which gets the same buffers.
    private var received: Double = 0
    /// The audio clock when the model became ready (it's fed from then on).
    private var offset: Double = 0
    private var spans: [(voice: Int, start: Double, end: Double)] = []
    private let lock = NSLock()
    /// Progress messages for the notch (called on the main queue).
    var onStatus: ((String) -> Void)?

    /// Loads the model in the background; until it's ready, lines just stay "Others".
    func start() {
        queue.async {
            guard self.diarizer == nil, !self.loading else { return }
            self.loading = true
            let began = Date()
            // A first run downloads the model (about 250 MB); say so if loading takes a while.
            let slow = DispatchWorkItem { [weak self] in
                self?.onStatus?("Downloading the voice model so TeleNotch can tell people apart (about 250 MB, first time only). Transcription works meanwhile.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: slow)
            Task.detached(priority: .utility) {
                do {
                    let d = try await Self.loadModel()
                    slow.cancel()
                    if Date().timeIntervalSince(began) > 4 {
                        DispatchQueue.main.async { self.onStatus?("Voice model ready: other people now show as Speaker A, B, C.") }
                    }
                    self.queue.async { self.diarizer = d; self.offset = self.received; self.loading = false }
                } catch {
                    slow.cancel()
                    NSLog("TeleNotch speaker separation unavailable: \(error.localizedDescription)")
                    self.queue.async { self.loading = false }
                }
            }
        }
    }

    /// Sortformer (balanced, v2.1 weights): ~1 s behind live, up to 4 voices. In tests with three voices it
    /// labelled every line right, where LS-EEND merged two of them. TN_DIAR="lseend:dih3" etc. switches for testing.
    private static func loadModel() async throws -> any Diarizer {
        let spec = (ProcessInfo.processInfo.environment["TN_DIAR"] ?? "sortformer:balanced").split(separator: ":").map(String.init)
        if spec.first == "sortformer" {
            let configs: [String: SortformerConfig] = ["default": .default, "fast": .fastV2_1, "balanced": .balancedV2_1, "balanced2": .balancedV2,
                                                       "high": .highContextV2_1, "efficient": .efficientV2_1]
            let config = configs[spec.count > 1 ? spec[1] : "default"] ?? .default
            let d = SortformerDiarizer(config: config)
            d.initialize(models: try await SortformerModels.loadFromHuggingFace(config: config))
            return d
        }
        let name = spec.count > 1 ? spec[1] : "dih3"
        let variant = LSEENDVariant.allCases.first { $0.name == "ls_eend_" + name } ?? .dihard3
        return try await LSEENDDiarizer(variant: variant)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let mono = Self.mono(buffer) else { return }
        let rate = buffer.format.sampleRate
        queue.async {
            self.received += Double(mono.count) / rate
            guard let d = self.diarizer else { return }
            do {
                if let update = try d.process(samples: mono, sourceSampleRate: rate) {
                    let new = update.finalizedSegments.map {
                        (voice: $0.speakerIndex, start: Double($0.startTime) + self.offset, end: Double($0.endTime) + self.offset)
                    }
                    if !new.isEmpty { self.lock.lock(); self.spans += new; self.lock.unlock() }
                }
            } catch {
                NSLog("TeleNotch speaker separation stopped: \(error.localizedDescription)")
                self.diarizer = nil
            }
        }
    }

    /// The voice that spoke most between two points on the audio clock, if the model was sure enough.
    func voice(from start: Double, to end: Double) -> Int? {
        guard end > start else { return nil }
        lock.lock(); defer { lock.unlock() }
        var talk: [Int: Double] = [:]
        for s in spans where s.end > start && s.start < end {
            talk[s.voice, default: 0] += min(s.end, end) - max(s.start, start)
        }
        guard let best = talk.max(by: { $0.value < $1.value }), best.value >= 0.3 * (end - start) else { return nil }
        return best.key
    }

    var isReady: Bool { queue.sync { diarizer != nil } }

    /// For the self-test: what the tracker has so far.
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return "\(spans.count) spans, model \(diarizer == nil ? "not loaded" : "loaded"), audio \(String(format: "%.1f", received)) s, offset \(String(format: "%.1f", offset)) s: "
            + spans.prefix(30).map { "v\($0.voice) \(String(format: "%.1f-%.1f", $0.start, $0.end))" }.joined(separator: ", ")
    }

    func stop() {
        queue.async { self.diarizer = nil; self.received = 0; self.offset = 0 }
        lock.lock(); spans = []; lock.unlock()
    }

    private static func mono(_ b: AVAudioPCMBuffer) -> [Float]? {
        guard let ch = b.floatChannelData, b.frameLength > 0 else { return nil }
        let n = Int(b.frameLength), c = Int(b.format.channelCount)
        var out = [Float](repeating: 0, count: n)
        if b.format.isInterleaved {
            let p = ch[0]
            for i in 0..<n { var s: Float = 0; for k in 0..<c { s += p[i * c + k] }; out[i] = s / Float(c) }
        } else {
            for k in 0..<c { let p = ch[k]; for i in 0..<n { out[i] += p[i] } }
            if c > 1 { for i in 0..<n { out[i] /= Float(c) } }
        }
        return out
    }
}

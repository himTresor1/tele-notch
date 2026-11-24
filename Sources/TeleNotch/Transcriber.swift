import AVFAudio
import Foundation
import Speech

enum Speaker: String { case me = "Me", others = "Others" }

struct Line: Identifiable {
    let id = UUID()
    let speaker: Speaker
    var text: String
    let time: Date
}

/// The meeting so far: finished segments plus one in-progress segment per speaker.
final class Transcript: ObservableObject {
    /// Each finished piece of speech, in order. Echoes of "Others" picked up by the mic are removed.
    @Published private(set) var segments: [Line] = []
    @Published private(set) var live: [Speaker: String] = [:]

    /// Segments merged into readable lines while the same person keeps talking.
    var lines: [Line] {
        var out: [Line] = []
        for seg in segments {
            if var last = out.last, last.speaker == seg.speaker, seg.time.timeIntervalSince(last.time) < 20 {
                last.text += " " + seg.text
                out[out.count - 1] = last
            } else {
                out.append(seg)
            }
        }
        return out
    }

    func update(_ speaker: Speaker, text: String, isFinal: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            if isFinal {
                self.live[speaker] = nil
                guard !t.isEmpty else { return }
                self.addFinal(Line(speaker: speaker, text: t, time: Date()))
            } else {
                // Don't show the mic's live echo of what someone else is saying right now.
                if speaker == .me, let other = self.live[.others], Echo.isEcho(t, of: other) || Echo.isLooseEcho(t, of: other) {
                    self.live[.me] = nil; return
                }
                self.live[speaker] = t.isEmpty ? nil : t
            }
        }
    }

    // MARK: Echo removal
    // With speakers instead of headphones the mic also hears the other people, so their words would
    // show up a second time as "Me" and Claude would think you said them. Both transcribers hear the
    // same sentence within a few seconds of each other, in either order, so compare against the other side.

    // Someone in the same room who's also on the call reaches your mic faintly, so that copy is garbled and
    // only loosely matches what the call delivers. Within a few seconds of each other a loose match counts.
    private static let echoWindow: TimeInterval = 15
    private static let looseWindow: TimeInterval = 8

    private func addFinal(_ seg: Line) {
        let others = { (window: TimeInterval) -> String in
            self.segments.filter { $0.speaker == .others && abs(seg.time.timeIntervalSince($0.time)) < window }
                .map(\.text).joined(separator: " ") + " " + (self.live[.others] ?? "")
        }
        switch seg.speaker {
        case .me:
            if Echo.isEcho(seg.text, of: others(Self.echoWindow)) || Echo.isLooseEcho(seg.text, of: others(Self.looseWindow)) { return }
            segments.append(seg)
        case .others:
            // A "Me" segment that arrived first may be the echo of this one.
            segments.removeAll { me in
                guard me.speaker == .me else { return false }
                let gap = seg.time.timeIntervalSince(me.time)
                return (gap < Self.echoWindow && Echo.isEcho(me.text, of: seg.text))
                    || (gap < Self.looseWindow && Echo.isLooseEcho(me.text, of: seg.text))
            }
            segments.append(seg)
        }
    }

    func clear() { segments = []; live = [:] }

    /// For the self-test: add a finished segment directly, `ago` seconds in the past.
    func inject(_ speaker: Speaker, _ text: String, ago: TimeInterval) {
        segments.append(Line(speaker: speaker, text: text, time: Date().addingTimeInterval(-ago)))
    }

    /// Plain-text transcript of what was said after `since`, plus whatever is still being said.
    func text(since: Date = .distantPast) -> String {
        var out = Transcript.merge(segments.filter { $0.time >= since }).map { "\($0.speaker.rawValue): \($0.text)" }
        for s in [Speaker.others, .me] { if let l = live[s] { out.append("\(s.rawValue): \(l) …") } }
        return out.joined(separator: "\n")
    }

    /// Finished speech between two times (used for the rolling notes).
    func text(from: Date, to: Date) -> String {
        Transcript.merge(segments.filter { $0.time >= from && $0.time < to })
            .map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
    }

    /// The last `seconds` of the meeting, word for word.
    func recent(seconds: TimeInterval) -> String { text(since: Date().addingTimeInterval(-seconds)) }

    /// Joins your consecutive lines. "Others" lines stay separate: each is a stretch of speech between pauses,
    /// and a new one may be a different person, which Claude uses to tell people apart.
    private static func merge(_ segs: [Line]) -> [Line] {
        var out: [Line] = []
        for seg in segs {
            if var last = out.last, last.speaker == seg.speaker, seg.speaker == .me { last.text += " " + seg.text; out[out.count - 1] = last }
            else { out.append(seg) }
        }
        return out
    }
}

enum Echo {
    private static let numbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                                  "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map { numbers[String($0)] ?? String($0) }
    }

    /// True when most of `mine` (3+ words) also appears in `others`: the mic heard the speakers.
    static func isEcho(_ mine: String, of others: String) -> Bool {
        let m = words(mine)
        guard m.count >= 3 else { return false }
        let bag = Set(words(others))
        guard !bag.isEmpty else { return false }
        let hits = m.filter { bag.contains($0) }.count
        return Double(hits) / Double(m.count) >= 0.7
    }

    /// Little words every sentence shares, ignored by the loose match.
    private static let common: Set<String> = ["the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "at",
        "for", "with", "is", "it", "its", "it's", "that", "this", "be", "was", "are", "i", "you", "we", "they", "he",
        "she", "me", "my", "your", "our", "do", "not", "yeah", "yes", "no", "ok", "okay", "um", "uh", "like", "just",
        "have", "has", "if", "what", "there", "then", "can", "will", "think", "know", "right", "well"]

    /// A faint, half-misheard copy: at least 3 meaningful words, and half of them also in `others`.
    static func isLooseEcho(_ mine: String, of others: String) -> Bool {
        let m = words(mine).filter { !common.contains($0) }
        guard m.count >= 3 else { return false }
        let bag = Set(words(others).filter { !common.contains($0) })
        guard !bag.isEmpty else { return false }
        let hits = m.filter { bag.contains($0) }.count
        return Double(hits) / Double(m.count) >= 0.5
    }
}

/// One on-device SpeechAnalyzer per audio source.
final class StreamTranscriber {
    let speaker: Speaker
    private let transcript: Transcript
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private let convertQueue = DispatchQueue(label: "telenotch.convert")

    init(speaker: Speaker, transcript: Transcript) {
        self.speaker = speaker
        self.transcript = transcript
    }

    static func locale() async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { return l }
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) { return l }
        throw TranscriberError.unavailable
    }

    /// True when Apple's speech model for this language still has to be downloaded.
    static func needsAssets(locale: Locale) async throws -> Bool {
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return try await AssetInventory.assetInstallationRequest(supporting: [probe]) != nil
    }

    /// Downloads the on-device speech model the first time (a one-off, a few hundred MB).
    static func prepareAssets(locale: Locale) async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await req.downloadAndInstall()
        }
    }

    func start(locale: Locale) async throws {
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw TranscriberError.unavailable }
        analyzerFormat = fmt
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation = cont
        let speaker = self.speaker, transcript = self.transcript
        resultsTask = Task {
            do {
                for try await r in module.results {
                    transcript.update(speaker, text: String(r.text.characters), isFinal: r.isFinal)
                }
            } catch {
                NSLog("TeleNotch transcription (\(speaker.rawValue)) ended: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        convertQueue.async { [weak self] in
            guard let self, let cont = self.continuation, let out = self.convert(buffer) else { return }
            cont.yield(AnalyzerInput(buffer: out))
        }
    }

    /// Resample / downmix to the format the speech model wants.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let fmt = analyzerFormat else { return nil }
        if buffer.format == fmt { return buffer }
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: fmt)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * fmt.sampleRate / buffer.format.sampleRate) + 512
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return buffer
        }
        if status == .error { NSLog("TeleNotch convert error: \(String(describing: err))"); return nil }
        return out.frameLength > 0 ? out : nil
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        analyzer = nil
        converter = nil
    }
}

enum TranscriberError: LocalizedError {
    case unavailable
    var errorDescription: String? { "On-device speech recognition isn't available for your language on this Mac." }
}

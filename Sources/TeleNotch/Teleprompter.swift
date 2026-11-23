import AppKit
import Combine

/// Script scrolling state. The view reads `offset`; a 60 Hz timer advances it while playing.
final class Teleprompter: ObservableObject {
    @Published var script: String = Prefs.script
    @Published var offset: CGFloat = 0
    @Published var playing = false
    @Published var wpm: Double = Prefs.wpm           // words per minute
    private var wordCount = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    private var timer: Timer?
    private var last = Date()

    init() { wordCount = Self.countWords(script) }

    static func countWords(_ s: String) -> Int { s.split { $0.isWhitespace }.count }

    /// `save: false` is for self-tests, so they never overwrite the script you pasted.
    func setScript(_ s: String, save: Bool = true) {
        if save { Prefs.script = s }
        script = s
        wordCount = Self.countWords(s)
        offset = 0
    }

    /// Words per minute → points per second, using how tall the script actually renders.
    private var pointsPerSecond: Double {
        guard wordCount > 0, contentHeight > 0 else { return 0 }
        return wpm / 60 * Double(contentHeight) / Double(wordCount)
    }

    /// No script yet: the notch shows "Paste your script" instead.
    var isEmpty: Bool { script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func togglePlay() { playing ? pause() : play() }

    func play() {
        guard !isEmpty else { return }
        playing = true
        last = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        playing = false
        timer?.invalidate(); timer = nil
    }

    func changeSpeed(by delta: Double) {
        Prefs.wpm = wpm + delta
        wpm = Prefs.wpm
    }

    /// Jump back roughly three lines.
    func back() {
        offset = max(0, offset - CGFloat(Prefs.fontSize) * 1.25 * 3)
    }

    func restart() { offset = 0 }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(last)
        last = now
        let maxOffset = max(0, contentHeight - viewportHeight * 0.3)
        offset = min(maxOffset, offset + CGFloat(pointsPerSecond * dt))
        if offset >= maxOffset && contentHeight > 0 { pause() }
    }
}

import AVFAudio
import Foundation

// MARK: - Prompts

enum Prompts {
    /// Used for "Answer for me". Stable text, so it is prompt-cached.
    static let answer = """
    You are a live earpiece for one person in a meeting. You see an automatic transcript of the meeting from their Mac. \
    Lines marked "Me" are the person you are helping (their microphone). Lines marked "Others" are everyone else \
    (the audio their computer plays); several different people may be speaking under "Others". Speech recognition makes \
    mistakes, so expect misheard words and missing punctuation, and work out what was meant.

    The person lost track of the conversation and has just been put on the spot. They will read your words aloud \
    straight away, word for word, from a small screen next to their camera. So:

    - Speak as them. Write in the first person, in natural spoken language, as the exact words they will say. Never \
    talk about them or to them ("you could say…", "they think…"), and never mention a transcript, notes, AI or that \
    someone is helping.
    - Respond to the most recent question or request aimed at them. If nobody asked them anything directly, give \
    their contribution to the point being discussed right now.
    - Take a side immediately. The first sentence states a clear position ("I'd go with the second option.", "I \
    disagree, and here's why."). Commit to one view: do not list both sides, do not say "it depends", do not hedge or \
    stall. Back it with one or two concrete reasons, using what was said in the meeting where you can. Don't make \
    up specific facts, projects, names or numbers that weren't mentioned; general reasoning is fine. For a factual \
    question, give your best answer plainly.
    - Be short: two to four sentences, about fifteen seconds of speech. Short, easy sentences that read well aloud.
    - Plain text only: no markdown, bullet points, headings, quotation marks around the answer, labels or stage directions.
    - Use the language the meeting is held in, and match how the person speaks when their own lines show it.

    In presentation mode, the person is presenting and taking questions from the audience. Answer the question that \
    was actually asked, based on what you heard. Their presentation script is background only: use a fact from it if \
    it directly helps, but do not recite it or steer back to it. A direct, confident answer to the question matters more.
    """

    /// Used for "Catch me up".
    static let catchUp = """
    You help one person who drifted off in a live meeting get back on track in a few seconds. You see an automatic \
    transcript ("Me" is the person, "Others" is everyone else, possibly several people) and running notes. Speech \
    recognition makes mistakes; work out what was meant.

    Reply with at most three short lines, each starting with "• ", written to the person:
    • what is being discussed right now
    • where people stand (who is arguing what), or what was just decided
    • if someone just asked them something, the question itself in a few words ("Asked you: four days or two?"); \
    otherwise exactly "Nothing asked of you."
    Keep each line under 25 words. Plain text, no other formatting, no preamble.
    """

    /// Used every ~45 s in the background.
    static let notes = """
    You keep running notes of a live meeting for one participant ("Me"; everyone else appears as "Others"). The \
    transcript comes from speech recognition, so fix obvious mishearings. Given the current notes and the newest part \
    of the transcript, return the updated notes: the topic, decisions, each side's positions and arguments, open \
    questions, anything asked of Me, and names or numbers that matter. Keep them under 250 words, as terse lines. \
    Drop details that no longer matter. Output only the notes.
    """
}

// MARK: - Notch messages

struct Banner: Equatable {
    enum Kind { case info, warning, error }
    enum Action: Equatable { case openSettings, openMicPrivacy, openAudioPrivacy, openWelcome }
    let id = UUID()
    let text: String
    let kind: Kind
    var action: Action?
    var actionTitle: String {
        switch action {
        case .openSettings: return "Open Settings"
        case .openMicPrivacy, .openAudioPrivacy: return "Open Privacy Settings"
        case .openWelcome: return "Open Guide"
        case nil: return ""
        }
    }
}

// MARK: - Copilot

@MainActor
final class Copilot: ObservableObject {
    @Published var listening = false
    @Published var starting = false
    @Published var showingAnswer = false
    @Published var answerText = ""
    @Published var answerTitle = ""
    @Published var streaming = false
    @Published var error: String?
    @Published var status = "Not listening"
    @Published var banner: Banner?
    @Published var showingHelp = false
    @Published private(set) var notes = ""

    let transcript = Transcript()
    var onNeedsPanel: (() -> Void)?
    /// Asks the user (once) to confirm they'll tell people they're transcribing. Returns false to cancel.
    var confirmConsent: (() -> Bool)?
    var onBannerAction: ((Banner.Action) -> Void)?

    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private var micT: StreamTranscriber?
    private var sysT: StreamTranscriber?
    // Keeping listening alive when audio devices change
    private var watcher: AudioDeviceWatcher?
    private var watchdog: Timer?
    private var restartWork: DispatchWorkItem?
    private var restarting = false
    private var restartAttempts = 0
    private var hearsOthers = false
    private let micBeat = Heartbeat()
    private let sysBeat = Heartbeat()
    private var notesTimer: Timer?
    private var notesCoveredUntil = Date.distantPast
    private var notesBusy = false
    private var notesFailures = 0
    private var answerTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?

    // MARK: Messages in the notch

    /// Shows a message at the bottom of the notch panel (and the panel itself, if it's hidden).
    func notify(_ text: String, _ kind: Banner.Kind = .info, action: Banner.Action? = nil, seconds: Double? = nil) {
        let b = Banner(text: text, kind: kind, action: action)
        banner = b
        onNeedsPanel?()
        bannerTask?.cancel()
        let secs = seconds ?? (kind == .info ? 4 : 12)
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(secs))
            if !Task.isCancelled, self?.banner?.id == b.id { self?.banner = nil }
        }
    }

    func performBannerAction() {
        guard let a = banner?.action else { return }
        banner = nil
        onBannerAction?(a)
    }

    // MARK: Listening

    func toggleListening() {
        if listening { Task { await stopListening() } } else { Task { await startListening() } }
    }

    func startListening() async {
        guard !listening, !starting else { return }
        if !Prefs.consentAcknowledged, let confirm = confirmConsent, !confirm() { return }
        starting = true
        defer { starting = false }
        status = "Starting…"
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                status = "Microphone access is off."
                notify("TeleNotch can't use the microphone. Turn it on in Privacy & Security → Microphone.", .error,
                       action: .openMicPrivacy)
                return
            }
            let locale = try await StreamTranscriber.locale()
            if try await StreamTranscriber.needsAssets(locale: locale) {
                status = "Downloading the speech model (first time only)…"
                notify("Downloading Apple's speech model. First time only, about a minute…", .info, seconds: 120)
                try await StreamTranscriber.prepareAssets(locale: locale)
            }

            let m = StreamTranscriber(speaker: .me, transcript: transcript)
            let s = StreamTranscriber(speaker: .others, transcript: transcript)
            try await m.start(locale: locale)
            try await s.start(locale: locale)
            micT = m; sysT = s
            let sysOK = try startCapture()
            listening = true
            notesCoveredUntil = Date()
            startNotesTimer()
            startKeepAlive()
            if sysOK {
                status = "Listening"
                notify(mic.avoidedBluetooth
                       ? "Listening, with the \(mic.deviceName) so your Bluetooth headphones keep their sound quality. Press ⌃⌥↩ when asked something."
                       : "Listening. Press ⌃⌥↩ when someone asks you something.")
            } else {
                status = "Listening to your mic only"
                notify("Listening to your mic only: TeleNotch can't hear the other people. Allow it under Screen & System Audio Recording.",
                       .warning, action: .openAudioPrivacy)
            }
        } catch {
            status = "Couldn't start listening: \(error.localizedDescription)"
            notify("Couldn't start listening: \(error.localizedDescription)", .error)
            await stopListening()
        }
    }

    func stopListening() async {
        let was = listening
        stopKeepAlive()
        mic.stop()
        system.stop()
        await micT?.stop(); await sysT?.stop()
        micT = nil; sysT = nil
        notesTimer?.invalidate(); notesTimer = nil
        listening = false
        if was { status = "Not listening"; notify("Stopped listening.") }
    }

    // MARK: Audio capture that survives device changes

    /// Starts the mic and system-audio capture into the running transcribers. Returns whether system audio works.
    private func startCapture() throws -> Bool {
        guard let m = micT, let s = sysT else { return false }
        micBeat.beat(); sysBeat.beat()
        let micBeat = micBeat, sysBeat = sysBeat
        try mic.start { micBeat.beat(); m.feed($0) }
        mic.onConfigurationChange = { [weak self] in self?.scheduleRestart() }
        do {
            try system.start { sysBeat.beat(); s.feed($0) }
            hearsOthers = true
        } catch {
            hearsOthers = false
            NSLog("TeleNotch system audio failed: \(error.localizedDescription)")
        }
        return hearsOthers
    }

    private func startKeepAlive() {
        restartAttempts = 0
        watcher = AudioDeviceWatcher { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRestart() }
        }
        // Audio arrives several times a second, even in silence. If a source goes quiet, its stream died.
        watchdog = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAudioFlowing() }
        }
    }

    private func stopKeepAlive() {
        watcher = nil
        watchdog?.invalidate(); watchdog = nil
        restartWork?.cancel(); restartWork = nil
    }

    /// Devices often change in bursts (headphones connecting, a call app switching modes): wait for it to settle.
    private func scheduleRestart() {
        guard listening else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { Task { await self?.restartCapture(announce: true) } }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func checkAudioFlowing() {
        guard listening, !restarting else { return }
        let now = Date()
        let micDead = now.timeIntervalSince(micBeat.last) > 8
        let sysDead = hearsOthers && now.timeIntervalSince(sysBeat.last) > 8
        guard micDead || sysDead else { restartAttempts = 0; return }
        if restartAttempts < 2 {
            restartAttempts += 1
            Task { await restartCapture(announce: false) }
        } else if restartAttempts == 2 {
            restartAttempts += 1
            let what = micDead ? "your microphone (\(mic.deviceName))" : "the other people (your Mac's sound)"
            notify("TeleNotch isn't getting any audio from \(what). Press ⌃⌥L twice to restart listening, or check Sound in System Settings.",
                   .warning)
        }
    }

    /// Restarts the mic and system-audio capture, keeping the transcript and transcribers.
    private func restartCapture(announce: Bool) async {
        guard listening, !restarting else { return }
        restarting = true
        defer { restarting = false }
        mic.stop()
        system.stop()
        try? await Task.sleep(for: .milliseconds(400))
        guard listening else { return }
        do {
            let ok = try startCapture()
            if announce {
                notify(ok ? "Audio devices changed. Still listening, with the \(mic.deviceName)."
                          : "Audio devices changed. Listening to your mic only: TeleNotch can't hear the other people right now.",
                       ok ? .info : .warning)
            }
        } catch {
            notify("Lost the microphone after an audio change: \(error.localizedDescription). Press ⌃⌥L to try again.", .error)
            await stopListening()
        }
    }

    func newMeeting() {
        transcript.clear()
        notes = ""
        notesCoveredUntil = Date()
        notify("New meeting: transcript and notes cleared.")
    }

    // MARK: Rolling notes

    private func startNotesTimer() {
        notesTimer?.invalidate()
        notesTimer = Timer.scheduledTimer(withTimeInterval: Prefs.summaryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.updateNotes() }
        }
    }

    func updateNotes(force: Bool = false) async {
        guard !notesBusy, Keychain.apiKey != nil else { return }
        if force { notesCoveredUntil = .distantPast }
        let cut = Date()
        let chunk = transcript.text(from: notesCoveredUntil, to: cut)
        guard !chunk.isEmpty else { return }
        notesBusy = true
        defer { notesBusy = false }
        let user = """
        <current_notes>
        \(notes.isEmpty ? "(none yet)" : notes)
        </current_notes>

        <new_transcript>
        \(chunk)
        </new_transcript>
        """
        do {
            let updated = try await ClaudeClient.complete(system: Prompts.notes, user: user)
            if !updated.isEmpty { notes = updated; notesCoveredUntil = cut }
            notesFailures = 0
        } catch {
            NSLog("TeleNotch notes update failed: \(error.localizedDescription)")
            notesFailures += 1
            // One miss is harmless (the next update catches up); say something if it keeps failing.
            if notesFailures == 2 && listening {
                notify("Couldn't update the meeting notes: \(error.localizedDescription)", .warning)
            }
        }
    }

    // MARK: Answer / catch up

    func answer() { ask(title: "Say this", system: Prompts.answer, instruction: answerInstruction(Prefs.mode)) }

    func catchUp() {
        ask(title: "Catch up", system: Prompts.catchUp, instruction: "Catch me up on what's happening right now.")
    }

    /// A made-up meeting, so you can see an answer appear in the notch without being in a call.
    func demo() {
        let t = Transcript()
        t.inject(.others, "So the proposal is that we move the whole team to four days in the office next quarter.", ago: 60)
        t.inject(.others, "I think that's a mistake, our output went up last year with people at home.", ago: 40)
        t.inject(.others, "Could we do two anchor days instead, Tuesday and Thursday?", ago: 25)
        t.inject(.others, "Okay, what do you think? Four days, or two anchor days?", ago: 5)
        ask(title: "Demo: say this", system: Prompts.answer,
            user: userMessage(instruction: answerInstruction(.meeting), mode: .meeting, transcript: t, includeNotes: false))
    }

    func dismissAnswer() {
        answerTask?.cancel()
        showingAnswer = false
        streaming = false
    }

    /// Everything Claude sees for an answer or catch-up: your profile, the meeting so far, and the instruction.
    func userMessage(instruction: String, mode: CopilotMode, transcript t: Transcript? = nil, includeNotes: Bool = true) -> String {
        let recent = (t ?? transcript).recent(seconds: 180)
        var parts: [String] = []
        let about = Prefs.aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty { parts.append("<about_me>\n\(about)\n</about_me>") }
        let ctx = Prefs.meetingContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty && includeNotes { parts.append("<meeting_context>\n\(ctx)\n</meeting_context>") }
        if mode == .presentation {
            let script = String(Prefs.script.prefix(8000))
            parts.append("<presentation_script>\n\(script)\n</presentation_script>")
        }
        if !notes.isEmpty && includeNotes { parts.append("<earlier_in_the_meeting>\n\(notes)\n</earlier_in_the_meeting>") }
        parts.append("<last_few_minutes>\n\(recent.isEmpty ? "(nothing transcribed yet)" : recent)\n</last_few_minutes>")
        parts.append(instruction)
        return parts.joined(separator: "\n\n")
    }

    func answerInstruction(_ mode: CopilotMode) -> String {
        mode == .presentation
            ? "Mode: presentation. I've just been asked a question by the audience. What do I say?"
            : "Mode: meeting. I've just been put on the spot. What do I say?"
    }

    private func ask(title: String, system: String, instruction: String) {
        if !listening && transcript.segments.isEmpty {
            notify("TeleNotch isn't listening yet, so it has nothing to go on. Press ⌃⌥L to start.", .warning)
        }
        ask(title: title, system: system, user: userMessage(instruction: instruction, mode: Prefs.mode))
    }

    private func ask(title: String, system: String, user: String) {
        answerTask?.cancel()
        showingHelp = false
        answerText = ""
        error = nil
        answerTitle = title
        guard Keychain.apiKey != nil else {
            notify("Add your Anthropic API key first.", .error, action: .openSettings)
            return
        }
        showingAnswer = true
        streaming = true
        onNeedsPanel?()

        answerTask = Task { [weak self] in
            do {
                try await ClaudeClient.stream(system: system, user: user, maxTokens: 4000, effort: "low") { piece in
                    guard let self, !Task.isCancelled else { return }
                    self.answerText += piece
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch let e as URLError {
                self?.error = e.code == .notConnectedToInternet ? "You're offline." : e.localizedDescription
            } catch {
                self?.error = error.localizedDescription
            }
            self?.streaming = false
        }
    }
}

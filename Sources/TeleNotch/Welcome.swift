import AppKit
import AVFAudio
import SwiftUI

// MARK: - Privacy settings shortcuts

enum Privacy {
    enum Pane: String { case microphone = "Privacy_Microphone", systemAudio = "Privacy_AudioCapture" }
    static func open(_ pane: Pane) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!)
    }
}

// MARK: - Permission checks

enum CheckState: Equatable { case unknown, working, ok, failed(String) }

@MainActor
enum PermissionCheck {
    static var micGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    /// Captures system audio for a few seconds while playing a short sound, and reports whether any arrived.
    /// The first time, macOS asks for "system audio recording" permission here.
    static func testSystemAudio() async -> CheckState {
        let cap = SystemAudioCapture()
        let peak = PeakMeter()
        do { try cap.start { peak.add($0) } } catch { return .failed(error.localizedDescription) }
        defer { cap.stop() }
        for _ in 0..<10 {   // up to ~10 s, so there's time to click Allow on the macOS prompt
            NSSound(named: "Glass")?.play()
            try? await Task.sleep(for: .seconds(1))
            if peak.value > 0.001 { return .ok }
        }
        return .failed("No sound came through. Allow TeleNotch under Screen & System Audio Recording, and check your volume isn't muted.")
    }
}

final class PeakMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    var value: Float { lock.withLock { peak } }
    func add(_ b: AVAudioPCMBuffer) {
        guard let ch = b.floatChannelData else { return }
        var p: Float = 0
        for i in 0..<Int(b.frameLength) { p = max(p, abs(ch[0][i])) }
        lock.withLock { peak = max(peak, p) }
    }
}

// MARK: - Welcome guide

struct WelcomeView: View {
    @ObservedObject var copilot: Copilot
    @ObservedObject var teleprompter: Teleprompter
    let onFinish: () -> Void

    @State private var step = 0
    private let steps = ["Welcome", "API key", "Permissions", "How to use", "Try it"]

    // API key
    @State private var key = ""
    @State private var keyState: CheckState = Keychain.apiKey == nil ? .unknown : .ok
    @AppStorage("model") private var model = "claude-opus-5-5"
    // Permissions
    @State private var mic: CheckState = PermissionCheck.micGranted ? .ok : .unknown
    @State private var sys: CheckState = .unknown
    @State private var speech: CheckState = .unknown
    // Consent
    @AppStorage("consentAcknowledged") private var consent = false

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 18).padding(.bottom, 10)
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: apiKey
                    case 2: permissions
                    case 3: howTo
                    default: tryIt
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            footer.padding(16)
        }
        .frame(width: 580, height: 560)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                VStack(spacing: 4) {
                    Capsule().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 4)
                    Text(steps[i]).font(.caption2).foregroundStyle(i == step ? .primary : .secondary)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var footer: some View {
        HStack {
            if step > 0 { Button("Back") { step -= 1 } }
            Spacer()
            if step == 1 && keyState != .ok { Button("Skip for now") { step += 1 } }
            if step < steps.count - 1 {
                Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
            } else {
                Button("Finish") { onFinish() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to TeleNotch").font(.largeTitle.bold())
            Text("Your notes, right under your camera.").font(.title3).foregroundStyle(.secondary)
            feature("text.alignleft", "Teleprompter in the notch",
                    "Your script scrolls in a black panel that grows out of the notch, so you read while looking at the camera. It's set to stay out of screen shares and recordings.")
            feature("waveform", "Listens to your meeting",
                    "It transcribes your microphone (you) and your Mac's audio (everyone else), on your Mac. Works with Zoom, Meet, Teams, or anything else.")
            feature("text.bubble.fill", "Answers for you when you're on the spot",
                    "Lost the thread and someone asks what you think? Press ⌃⌥↩. Claude writes a short answer in your voice that takes a clear side, and you read it straight off the notch.")
            Text("This guide takes about two minutes.").foregroundStyle(.secondary)
        }
    }

    private var apiKey: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Claude").font(.title.bold())
            Text("TeleNotch uses your own Anthropic API key. You pay Anthropic directly for what you use. With Haiku, an hour-long meeting typically costs a few cents; Opus costs more but gives the most thoughtful answers.")
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                Label("Get a key at console.anthropic.com → API Keys → Create Key", systemImage: "arrow.up.right.square")
            }
            HStack {
                SecureField(Keychain.apiKey != nil ? "Saved. Paste a new key to replace it" : "Paste your key (sk-ant-…)", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button("Save & Test") { Task { await testKey() } }
                    .disabled(key.isEmpty && Keychain.apiKey == nil)
            }
            status(keyState, ok: "Key works. You're connected.")
            Picker("Model", selection: $model) {
                ForEach(Prefs.models, id: \.0) { Text($0.1).tag($0.0) }
            }
            .frame(maxWidth: 380)
            Text("The key is stored in your Mac's Keychain. You can change any of this later in Settings (⌃⌥,).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Let TeleNotch listen").font(.title.bold())
            Text("macOS will ask you to allow each of these. Audio never leaves your Mac; only text goes to Claude when you ask for an answer.")
                .fixedSize(horizontal: false, vertical: true)
            permissionRow("mic.fill", "Microphone", "So it knows what you said, shown as “Me”.", mic,
                          buttonTitle: mic == .ok ? nil : "Allow", action: { Task { await askMic() } },
                          fix: { Privacy.open(.microphone) })
            permissionRow("speaker.wave.2.fill", "System audio", "So it hears the other people in your call, shown as “Others”. It plays a short sound to test.", sys,
                          buttonTitle: sys == .ok ? nil : "Allow & Test", action: { Task { sys = .working; sys = await PermissionCheck.testSystemAudio() } },
                          fix: { Privacy.open(.systemAudio) })
            permissionRow("arrow.down.circle.fill", "Speech model", "Apple's on-device speech recognition. A one-time download.", speech,
                          buttonTitle: speech == .ok ? nil : "Download", action: { Task { await downloadSpeech() } }, fix: nil)
            Text("Tip: use headphones in calls. With speakers, your mic also hears the others. TeleNotch filters that out, but headphones work best.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await checkSpeech() }
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How to use it").font(.title.bold())
            Text("You only need a few shortcuts. The bottom of the notch always shows the keys that make sense right now, and you can click the buttons in the notch too.")
                .fixedSize(horizontal: false, vertical: true)
            shortcut("⌃⌥L", "Start / stop listening when a meeting starts")
            shortcut("⌃⌥↩", "Answer for me: what should I say? Press again to go back to your script")
            shortcut("⌃⌥P", "Play / pause your script")
            shortcut("⌃⌥/", "Show every shortcut in the notch")
            shortcut("⌃⌥Space", "Hide the notch and bring it back. The arrow button at the top right of the notch hides it too")
            Text("Can't find the menu bar icon? It can hide behind the notch. Use ⌃⌥, for Settings, or the ⋯ button in the notch.")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Tell people when you're transcribing", systemImage: "person.2.wave.2.fill").font(.headline)
                    Text("TeleNotch writes down what everyone in the call says. In many places, recording or transcribing a conversation needs everyone's consent, and it's the respectful thing to do anyway. A red dot in the notch shows whenever it's listening.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Toggle("I'll let people know when I'm transcribing a call", isOn: $consent)
                }
                .padding(6)
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try it").font(.title.bold())
            Text("Look at the notch at the top of your screen.")
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.bubble.fill").font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 6) {
                    Text("See an answer").font(.headline)
                    Text("Plays a short made-up meeting (“four days in the office, or two?”) and shows what Claude would have you say.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Show a Demo Answer") { copilot.demo() }.disabled(Keychain.apiKey == nil)
                    if Keychain.apiKey == nil { Text("Add your API key first (step 2).").font(.caption).foregroundStyle(.orange) }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "play.fill").font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scroll a script").font(.headline)
                    Text("Starts the teleprompter. Paste your own script any time with ⌃⌥E.").foregroundStyle(.secondary)
                    Button("Start the Teleprompter") { copilot.dismissAnswer(); teleprompter.restart(); teleprompter.play() }
                }
            }
            Text("That's it. When your next meeting starts, press ⌃⌥L.").padding(.top, 6)
        }
    }

    // MARK: Pieces

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcut(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(keys).font(.system(size: 15, weight: .bold, design: .rounded))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                .frame(width: 72, alignment: .leading)
            Text(text)
        }
    }

    private func permissionRow(_ icon: String, _ title: String, _ why: String, _ state: CheckState,
                               buttonTitle: String?, action: @escaping () -> Void, fix: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                status(state, ok: "Done")
                if case .failed = state, let fix { Button("Open Privacy Settings", action: fix).controlSize(.small) }
            }
            Spacer()
            if state == .working { ProgressView().controlSize(.small) }
            else if let buttonTitle { Button(buttonTitle, action: action) }
        }
    }

    @ViewBuilder private func status(_ s: CheckState, ok: String) -> some View {
        switch s {
        case .ok: Label(ok, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .failed(let msg): Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        case .working: Label("Checking…", systemImage: "hourglass").foregroundStyle(.secondary).font(.callout)
        case .unknown: EmptyView()
        }
    }

    // MARK: Actions

    private func testKey() async {
        if !key.isEmpty { Keychain.setAPIKey(key); key = "" }
        keyState = .working
        do {
            _ = try await ClaudeClient.complete(system: "Reply with the single word OK.", user: "Test", maxTokens: 2000)
            keyState = .ok
        } catch {
            keyState = .failed(error.localizedDescription)
        }
    }

    private func askMic() async {
        mic = .working
        let ok = await AVAudioApplication.requestRecordPermission()
        mic = ok ? .ok : .failed("Microphone access is off for TeleNotch.")
    }

    private func checkSpeech() async {
        guard speech == .unknown, let locale = try? await StreamTranscriber.locale() else { return }
        if (try? await StreamTranscriber.needsAssets(locale: locale)) == false { speech = .ok }
    }

    private func downloadSpeech() async {
        speech = .working
        do {
            let locale = try await StreamTranscriber.locale()
            try await StreamTranscriber.prepareAssets(locale: locale)
            speech = .ok
        } catch {
            speech = .failed(error.localizedDescription)
        }
    }
}

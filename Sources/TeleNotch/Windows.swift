import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var copilot: Copilot
    @AppStorage("model") private var model = "claude-opus-5-5"
    @AppStorage("mode") private var mode = CopilotMode.meeting.rawValue
    @AppStorage("aboutMe") private var aboutMe = ""
    @AppStorage("meetingContext") private var meetingContext = ""
    @AppStorage("participants") private var participants = ""
    @AppStorage("fontSize") private var fontSize = 22.0
    @AppStorage("panelWidth") private var panelWidth = 600.0
    @AppStorage("panelHeight") private var panelHeight = 190.0
    @AppStorage("mirror") private var mirror = false
    @AppStorage("summaryInterval") private var summaryInterval = 45.0
    @AppStorage("showHints") private var showHints = true
    @AppStorage("nearVoiceOnly") private var nearVoiceOnly = true
    @AppStorage("separateVoices") private var separateVoices = true
    @AppStorage("glow") private var glow = true
    @AppStorage("SUAutomaticallyUpdate") private var autoUpdate = true
    var openWelcome: () -> Void = {}
    @State private var key = ""
    @State private var hasKey = Keychain.apiKey != nil
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Claude") {
                LabeledContent("API key") {
                    HStack {
                        SecureField(hasKey ? "Saved in Keychain" : "sk-ant-…", text: $key)
                        Button("Save") { Keychain.setAPIKey(key); key = ""; hasKey = Keychain.apiKey != nil }
                            .disabled(key.isEmpty)
                    }
                }
                Picker("Model", selection: $model) {
                    ForEach(Prefs.models, id: \.0) { Text($0.1).tag($0.0) }
                }
                Text("Faster models get the answer on screen sooner. Opus gives the most thoughtful answers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Copilot") {
                Picker("Mode", selection: $mode) {
                    ForEach(CopilotMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                VStack(alignment: .leading) {
                    Text("About me (name, role, views, how you talk)")
                    TextEditor(text: $aboutMe).frame(height: 60).font(.body)
                }
                VStack(alignment: .leading) {
                    Text("This meeting (agenda, goals)")
                    TextEditor(text: $meetingContext).frame(height: 60).font(.body)
                }
                Toggle("Tell the other voices apart (Speaker A, B, C…)", isOn: $separateVoices)
                VStack(alignment: .leading) {
                    Text("Who's in this meeting (one per line, e.g. \"Priya, product lead\")")
                    TextEditor(text: $participants).frame(height: 60).font(.body)
                    Text("Other people show up as Speaker A, B, C, told apart by voice. Names let Claude work out who's who and who's arguing what.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Update meeting notes every") {
                    Stepper("\(Int(summaryInterval)) s", value: $summaryInterval, in: 15...300, step: 15)
                }
                Toggle("Only hear my voice (ignore people nearby and background noise)", isOn: $nearVoiceOnly)
                Text("Your mic keeps only the voice closest to it. Turn this off if TeleNotch misses what you say. Changes apply the next time you start listening. Use headphones: with speakers, your mic also picks up the other people.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Teleprompter") {
                LabeledContent("Text size") { Slider(value: $fontSize, in: 14...44) }
                LabeledContent("Panel width") { Slider(value: $panelWidth, in: 380...1000) }
                LabeledContent("Panel height") { Slider(value: $panelHeight, in: 100...420) }
                Toggle("Mirror text (for a beam-splitter teleprompter)", isOn: $mirror)
                Toggle("Show shortcut hints at the bottom of the notch", isOn: $showHints)
                Toggle("Teal glow behind the text", isOn: $glow)
            }
            Section("Shortcuts") {
                ForEach(HotKeyAction.allCases, id: \.rawValue) { a in
                    LabeledContent(a.label) { Text(a.shortcut).monospaced() }
                }
            }
            Section("Updates") {
                LabeledContent("Version \(Updates.version)") {
                    Button("Check Now") { Updates.shared.checkNow() }
                }
                if Updates.shared.isConfigured {
                    Toggle("Install updates automatically", isOn: $autoUpdate)
                } else {
                    Text("Auto-updates turn on once this build has an update feed (feed-url.txt).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("General") {
                Button("Open the Welcome Guide…", action: openWelcome)
                Toggle("Open at login", isOn: $login)
                    .onChange(of: login) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                Text("Transcripts stay on your Mac. When you press Answer or Catch up, and every \(Int(summaryInterval)) s while listening, recent transcript text is sent to Claude. Recording laws differ: in some places everyone on a call must agree to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 600)
    }
}

// MARK: - Script editor

struct ScriptEditorView: View {
    @ObservedObject var teleprompter: Teleprompter
    @State private var text: String = Prefs.script

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text).font(.system(size: 15)).padding(4)
                // Saved as you type: the notch panel updates live, no button needed.
                .onChange(of: text) { _, t in teleprompter.setScript(t) }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste or type your script here. It scrolls in the notch at your speaking pace.")
                            .font(.system(size: 15)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text("\(text.split { $0.isWhitespace }.count) words · saved automatically").foregroundStyle(.secondary)
                Spacer()
                Button("Start Scrolling") { teleprompter.restart(); teleprompter.play() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(minWidth: 480, minHeight: 360)
    }
}

// MARK: - Live transcript

struct TranscriptView: View {
    @ObservedObject var copilot: Copilot
    @ObservedObject var transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(copilot.listening ? "Stop Listening" : "Start Listening") { copilot.toggleListening() }
                Button("New Meeting") { copilot.newMeeting() }
                Spacer()
            }
            Text(copilot.status).font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                List {
                    ForEach(transcript.lines, id: \.line.id) { l in row(l.label, me: l.line.speaker == .me, l.line.text, live: false) }
                    ForEach([Speaker.others, .me], id: \.self) { s in
                        if let t = transcript.live[s] { row(s.rawValue, me: s == .me, t, live: true) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: transcript.lines.count) { _, _ in proxy.scrollTo("bottom") }
            }
            if !copilot.notes.isEmpty {
                GroupBox("Running notes (sent to Claude)") {
                    ScrollView { Text(copilot.notes).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 110)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 460, minHeight: 420)
    }

    private func row(_ who: String, me: Bool, _ t: String, live: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(who).font(.caption.bold()).foregroundStyle(me ? .blue : .orange).frame(width: 72, alignment: .leading)
            Text(t).foregroundStyle(live ? .secondary : .primary).textSelection(.enabled)
        }
    }
}

// MARK: - Window helper

@MainActor
final class WindowBox {
    private var window: NSWindow?
    func close() { window?.close() }
    func show<V: View>(title: String, resizable: Bool = true, _ view: @autoclosure () -> V) {
        if window == nil {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
            if resizable { style.insert(.resizable) }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: style, backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: view())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

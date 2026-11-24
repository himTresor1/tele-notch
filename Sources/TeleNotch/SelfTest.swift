import SwiftUI
import AppKit
import AVFAudio
import Foundation

/// Developer self-test: `TeleNotch --selftest <claude|speech|system|mic> <out.txt> [audio file]`
/// Runs one part of the pipeline for real, writes what happened to <out.txt>, then quits.
@MainActor
enum SelfTest {
    static var out = ""
    static func log(_ s: String) { out += s + "\n"; print(s) }

    static func run(args: [String], copilot: Copilot) async {
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 2 else { return }
        let mode = args[i + 1], path = args[i + 2]
        let audio = args.count > i + 3 ? args[i + 3] : nil
        log("TeleNotch self-test: \(mode)  model=\(Prefs.model)  key=\(Keychain.apiKey == nil ? "MISSING" : "present")")
        switch mode {
        case "claude": await claude(copilot)
        case "speech": await speech(audio)
        case "system", "mic": await capture(mode, audio)
        case "full": await full(copilot, audio)
        case "render": render(copilot, path)
        case "devices": devices()
        case "filters": filters()
        default: log("unknown mode")
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
        exit(0)
    }

    // MARK: Claude: notes, answer (meeting + presentation), catch-up

    static func claude(_ copilot: Copilot) async {
        let t = copilot.transcript
        t.clear()
        t.inject(.others, "Okay so the proposal on the table is that we move the whole team to four days in the office starting next quarter.", ago: 170)
        t.inject(.others, "I think that's a mistake honestly, we hired half of these people as remote and our output went up last year.", ago: 150)
        t.inject(.others, "But onboarding has been rough, the juniors are struggling and nobody's around to help them.", ago: 120)
        t.inject(.me, "yeah I've seen that with the two new designers", ago: 100)
        t.inject(.others, "Could we do two anchor days instead, Tuesday and Thursday, and keep the rest flexible?", ago: 80)
        t.inject(.others, "Finance also says the lease renewal is due in March so we need a decision soon.", ago: 50)
        t.inject(.others, "Alright, we've heard from most people. What do you think, should we go four days or two anchor days?", ago: 10)

        await timed("NOTES (rolling summary)") {
            await copilot.updateNotes(force: true)
            return copilot.notes
        }
        await stream("ANSWER — meeting mode", system: Prompts.answer,
                     user: copilot.userMessage(instruction: copilot.answerInstruction(.meeting), mode: .meeting))
        await stream("CATCH UP", system: Prompts.catchUp,
                     user: copilot.userMessage(instruction: "Catch me up on what's happening right now.", mode: .meeting))

        t.clear()
        t.inject(.me, "Thank you. I'm happy to take any questions.", ago: 40)
        t.inject(.others, "Thanks, great talk. How is this actually different from just keeping my notes in another window? And isn't it kind of cheating to have AI answer for you?", ago: 8)
        await stream("ANSWER — presentation mode", system: Prompts.answer,
                     user: copilot.userMessage(instruction: copilot.answerInstruction(.presentation), mode: .presentation))
        t.clear()
    }

    static func timed(_ title: String, _ body: () async -> String) async {
        let start = Date()
        let r = await body()
        log("\n=== \(title)  [\(String(format: "%.1f", Date().timeIntervalSince(start))) s]\n\(r.isEmpty ? "(empty: check the API key / errors above)" : r)")
    }

    static func stream(_ title: String, system: String, user: String) async {
        let start = Date()
        var first: Date?
        var text = ""
        do {
            try await ClaudeClient.stream(system: system, user: user, maxTokens: 4000, effort: "low") { piece in
                if first == nil { first = Date() }
                text += piece
            }
            let ttft = first.map { String(format: "%.1f", $0.timeIntervalSince(start)) } ?? "-"
            log("\n=== \(title)  [first words \(ttft) s, done \(String(format: "%.1f", Date().timeIntervalSince(start))) s]\n\(text)")
        } catch {
            log("\n=== \(title)  FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: Render the notch panel to PNGs (script, answer, help) to check how it looks

    static func render(_ copilot: Copilot, _ path: String) {
        let tp = Teleprompter()
        let actions = PanelActions(editScript: {}, settings: {}, transcript: {}, welcome: {}, hide: {})
        func shot(_ name: String) {
            let view = PanelView(teleprompter: tp, copilot: copilot, state: PanelState(open: true), actions: actions, topInset: 32, notchWidth: 190)
                .frame(width: 600 + 2 * PanelView.ear, height: 222)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { log("render failed: \(name)"); return }
            let file = path.replacingOccurrences(of: ".png", with: "-\(name).png")
            try? png.write(to: URL(fileURLWithPath: file))
            log("wrote \(file)")
        }
        tp.setScript("", save: false)
        shot("empty")
        copilot.listening = true
        shot("empty-listening")
        copilot.listening = false
        tp.setScript("Good morning, everyone, and thanks for joining. Today I want to talk about one simple idea: what if your notes could follow you?", save: false)
        shot("script")
        copilot.listening = true
        copilot.showingAnswer = true
        copilot.answerTitle = "Say this"
        copilot.answerText = "I'd go with the two anchor days. Our output went up last year, and two shared days still give the juniors the help they need."
        shot("answer")
        copilot.showingAnswer = false
        copilot.showingHelp = true
        shot("help")
    }

    // MARK: Which microphone TeleNotch would pick

    static func devices() {
        if let d = AudioDevices.defaultInput() {
            log("default input: \(AudioDevices.name(d)) — bluetooth: \(AudioDevices.isBluetooth(d))")
        } else { log("default input: none") }
        log("built-in mic: \(AudioDevices.builtInInput().map(AudioDevices.name) ?? "none")")
        for d in AudioDevices.allDevices() { log("  device: \(AudioDevices.name(d)) — bluetooth: \(AudioDevices.isBluetooth(d))") }
        let mic = MicCapture()
        do {
            try mic.start { _ in }
            log("TeleNotch records from: \(mic.deviceName) (avoided Bluetooth: \(mic.avoidedBluetooth))")
            mic.stop()
        } catch { log("mic start failed: \(error.localizedDescription)") }
    }

    // MARK: Whole pipeline through the app's own Start Listening

    static func full(_ copilot: Copilot, _ path: String?) async {
        guard let path else { log("no audio file"); return }
        await copilot.startListening()
        log("status: \(copilot.status)")
        log("message: \(copilot.banner?.text ?? "-")")
        guard copilot.listening else { return }
        do {
            try await Task.sleep(for: .seconds(1))
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [path]
            try player.run()
            while player.isRunning { try await Task.sleep(for: .milliseconds(200)) }
            try await Task.sleep(for: .seconds(3))
        } catch { log("playback failed: \(error)") }
        log("\n=== LIVE TRANSCRIPT (as the app saw it)\n\(copilot.transcript.text())")
        await timed("NOTES") { await copilot.updateNotes(force: true); return copilot.notes }
        await stream("ANSWER — meeting mode", system: Prompts.answer,
                     user: copilot.userMessage(instruction: copilot.answerInstruction(.meeting), mode: .meeting))
        await stream("CATCH UP", system: Prompts.catchUp,
                     user: copilot.userMessage(instruction: "Catch me up on what's happening right now.", mode: .meeting))
        await copilot.stopListening()
    }

    // MARK: Speech recognition from a file

    static func speech(_ path: String?) async {
        guard let path, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { log("no audio file"); return }
        let transcript = Transcript()
        do {
            let locale = try await StreamTranscriber.locale()
            log("locale: \(locale.identifier)")
            let start = Date()
            try await StreamTranscriber.prepareAssets(locale: locale)
            log(String(format: "speech model ready in %.1f s", Date().timeIntervalSince(start)))
            let st = StreamTranscriber(speaker: .others, transcript: transcript)
            try await st.start(locale: locale)
            let fmt = file.processingFormat
            while file.framePosition < file.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) else { break }
                try file.read(into: buf)
                if buf.frameLength == 0 { break }
                st.feed(buf)
            }
            try await Task.sleep(for: .seconds(1))
            await st.stop()
            try await Task.sleep(for: .seconds(1))
            log("\n=== TRANSCRIPT\n\(transcript.text())")
        } catch {
            log("speech FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: Live capture while an audio file plays through the speakers

    static func capture(_ mode: String, _ path: String?) async {
        guard let path else { log("no audio file"); return }
        let transcript = Transcript()
        var buffers = 0
        var peak: Float = 0
        let lock = NSLock()
        do {
            if mode == "mic" {
                let ok = await AVAudioApplication.requestRecordPermission()
                log("microphone permission: \(ok)")
                if !ok { return }
            }
            let locale = try await StreamTranscriber.locale()
            try await StreamTranscriber.prepareAssets(locale: locale)
            let st = StreamTranscriber(speaker: mode == "mic" ? .me : .others, transcript: transcript)
            try await st.start(locale: locale)
            let onBuf: BufferHandler = { b in
                if let ch = b.floatChannelData {
                    var p: Float = 0
                    for i in 0..<Int(b.frameLength) { p = max(p, abs(ch[0][i])) }
                    lock.lock(); buffers += 1; peak = max(peak, p); lock.unlock()
                }
                st.feed(b)
            }
            let mic = MicCapture(), sys = SystemAudioCapture()
            if mode == "mic" { try mic.start(onBuf) } else { try sys.start(onBuf) }
            log("\(mode) capture started")
            try await Task.sleep(for: .seconds(1))
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [path]
            try player.run()
            while player.isRunning { try await Task.sleep(for: .milliseconds(200)) }
            try await Task.sleep(for: .seconds(2))
            mic.stop(); sys.stop()
            await st.stop()
            try await Task.sleep(for: .seconds(1))
            let (n, pk) = lock.withLock { (buffers, peak) }
            log("buffers received: \(n), peak level: \(String(format: "%.3f", pk))\(pk < 0.001 ? "  ← silence: permission probably denied" : "")")
            log("\n=== TRANSCRIPT\n\(transcript.text())")
        } catch {
            log("\(mode) capture FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: Background-voice filters

    static func filters() {
        // Echo matching: the colleague's sentence as the call delivers it, and as the room mic garbles it.
        let call = "We should move the launch to March so the design team has time to finish onboarding"
        let cases: [(String, String, Bool)] = [
            ("we should move the launch to march so the design team", call, true),          // clear room copy
            ("should move a lunch to march the design team has time", call, true),          // garbled room copy
            ("move lunch march design team finishing on boarding", call, true),             // very garbled
            ("I think we can ship the pricing page next week", call, false),                // you, other words
            ("yeah I think so too, that makes sense to me", call, false),                   // you, filler
            ("so the design is fine but I worry about march", call, false),                 // you, reacting to it
        ]
        var ok = 0
        for (mine, others, expect) in cases {
            let got = Echo.isEcho(mine, of: others) || Echo.isLooseEcho(mine, of: others)
            if got == expect { ok += 1 }
            log("\(got == expect ? "PASS" : "FAIL")  dropped=\(got)  expected=\(expect)  \"\(mine)\"")
        }
        log("echo: \(ok)/\(cases.count)\n")

        // Gate: 48 kHz mono buffers of ~85 ms. You at -20 dBFS, a colleague across the room at -36, room noise at -55.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        func buf(_ db: Float) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096)!; b.frameLength = 4096
            let amp = powf(10, db / 20) * sqrtf(2)
            for i in 0..<4096 { b.floatChannelData![0][i] = amp * sinf(Float(i) * 0.06) + Float.random(in: -0.0015...0.0015) }
            return b
        }
        let gate = VoiceGate()
        func run(_ label: String, _ db: Float, _ count: Int) {
            var open = 0
            for _ in 0..<count { let b = gate.process(buf(db)); if b.floatChannelData![0][100] != 0 || b.floatChannelData![0][2000] != 0 { open += 1 } }
            log("gate  \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(open)/\(count) buffers kept")
        }
        run("room noise (-55 dB)", -55, 30)
        run("you speaking (-20 dB)", -20, 30)
        run("pause (-55 dB)", -55, 30)
        run("colleague across room (-36 dB)", -36, 60)
        run("you again, softer (-25 dB)", -25, 30)
        run("colleague again (-36 dB)", -36, 30)
    }
}

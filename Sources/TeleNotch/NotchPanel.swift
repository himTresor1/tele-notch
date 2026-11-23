import AppKit
import SwiftUI

// MARK: - Notch geometry (adapted from NotchPeek, MIT)

struct Notch {
    let screen: NSScreen
    let rect: NSRect           // Cocoa coordinates (bottom-left origin)
    let isReal: Bool

    /// The notched screen; otherwise a pretend notch under the middle of the main screen's menu bar.
    /// TELENOTCH_FAKE_NOTCH=1 forces the fallback for testing.
    static func current() -> Notch? {
        if ProcessInfo.processInfo.environment["TELENOTCH_FAKE_NOTCH"] == nil {
            for s in NSScreen.screens {
                if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
                    let h = s.safeAreaInsets.top
                    return Notch(screen: s, rect: NSRect(x: l.maxX, y: s.frame.maxY - h, width: r.minX - l.maxX, height: h), isReal: true)
                }
            }
        }
        guard let s = NSScreen.main else { return nil }
        let h = NSStatusBar.system.thickness
        return Notch(screen: s, rect: NSRect(x: s.frame.midX - 100, y: s.frame.maxY - h, width: 200, height: h), isReal: false)
    }
}

// MARK: - Panel window

final class NotchPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clicks on the panel work straight away, without first activating TeleNotch.
final class ClickThroughHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What the panel's buttons and menu can do.
struct PanelActions {
    var editScript: () -> Void
    var settings: () -> Void
    var transcript: () -> Void
    var welcome: () -> Void
    var hide: () -> Void
}

@MainActor
final class NotchPanel {
    private var panel: NotchPanelWindow?
    private let teleprompter: Teleprompter
    private let copilot: Copilot
    private let actions: PanelActions
    var isVisible: Bool { panel?.isVisible ?? false }

    init(teleprompter: Teleprompter, copilot: Copilot, actions: PanelActions) {
        self.teleprompter = teleprompter
        self.copilot = copilot
        self.actions = actions
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isVisible == true { self?.layout() } }
        }
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        layout()
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    /// Re-applies size settings (called when preferences change).
    func layout() {
        guard let p = panel, let notch = Notch.current() else { return }
        let width = max(Prefs.panelWidth, notch.rect.width + 160)
        let topInset = notch.rect.height
        let height = Prefs.panelHeight + topInset
        let sf = notch.screen.frame
        var f = NSRect(x: notch.rect.midX - width / 2, y: sf.maxY - height, width: width, height: height)
        f.origin.x = min(max(f.minX, sf.minX + 4), sf.maxX - f.width - 4)
        p.setFrame(f, display: true)
        p.contentView = ClickThroughHostingView(rootView: PanelView(teleprompter: teleprompter, copilot: copilot, actions: actions,
                                                                   topInset: topInset, notchWidth: notch.rect.width))
    }

    private func makePanel() -> NotchPanelWindow {
        let p = NotchPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.isMovable = false
        // Ask macOS to leave this window out of screenshots, recordings and screen shares.
        p.sharingType = .none
        return p
    }
}

// MARK: - Panel content

struct PanelView: View {
    @ObservedObject var teleprompter: Teleprompter
    @ObservedObject var copilot: Copilot
    let actions: PanelActions
    let topInset: CGFloat
    let notchWidth: CGFloat
    @AppStorage("fontSize") private var fontSize = 22.0
    @AppStorage("mirror") private var mirror = false
    @AppStorage("showHints") private var showHints = true
    @AppStorage("glow") private var glow = true

    var body: some View {
        VStack(spacing: 0) {
            topBar.frame(height: max(topInset, 24))
            ZStack(alignment: .bottom) {
                Group {
                    if copilot.showingHelp { help }
                    else if copilot.showingAnswer { answer }
                    else if teleprompter.isEmpty { emptyState }
                    else { script }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if let b = copilot.banner { banner(b).padding(.bottom, 4).transition(.opacity) }
            }
            .padding(.horizontal, 20)
            if showHints { hints.padding(.horizontal, 16).padding(.bottom, 7).padding(.top, 3) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(panelBackground)
        .animation(.easeOut(duration: 0.15), value: copilot.banner)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Background: black, with teal light rising from the bottom edge behind the text

    private var panelBackground: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
        return shape.fill(Color.black)
            .overlay {
                if glow {
                    // Brighter while an answer is being written.
                    TealGlow(topInset: topInset, intensity: copilot.streaming ? 1.35 : 1)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(shape)
    }

    // MARK: Top bar: controls either side of the notch

    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
            // Left of the notch: listening + playback
            Button(action: copilot.toggleListening) {
                HStack(spacing: 5) {
                    if copilot.starting { ProgressView().controlSize(.mini) }
                    else { Circle().fill(copilot.listening ? Color.red : Color.gray.opacity(0.6)).frame(width: 7, height: 7) }
                    Text(copilot.listening ? "Listening" : copilot.starting ? "Starting…" : "Listen")
                }
            }
            .help(copilot.listening ? "Stop listening (⌃⌥L)" : "Start listening to the meeting (⌃⌥L)")
            if !copilot.showingAnswer && !copilot.showingHelp && !teleprompter.isEmpty {
                Button(action: teleprompter.togglePlay) { Image(systemName: teleprompter.playing ? "pause.fill" : "play.fill") }
                    .help("Play / pause the script (⌃⌥P)")
                Text("\(Int(teleprompter.wpm)) wpm").monospacedDigit().foregroundStyle(.secondary)
                    .help("Scroll speed in words per minute (⌃⌥↑ / ⌃⌥↓)")
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notchWidth + 16)  // the notch itself
            HStack(spacing: 10) {
            // Right of the notch: answer + menu
            if copilot.showingAnswer {
                if copilot.streaming { ProgressView().controlSize(.mini) }
                Text(copilot.answerTitle).foregroundStyle(.secondary)
                Button(action: copilot.dismissAnswer) { Label("Script", systemImage: "arrow.uturn.backward") }
                    .help("Back to your script (⌃⌥↩)")
            } else if copilot.showingHelp {
                Button { copilot.showingHelp = false } label: { Label("Done", systemImage: "checkmark") }
                    .help("Close the shortcut list (⌃⌥/)")
            } else {
                Button(action: copilot.answer) {
                    Label("Answer", systemImage: "text.bubble.fill")
                }
                .help("Write what I should say right now (⌃⌥↩)")
            }
            Menu {
                Button("Edit Script…  ⌃⌥E", action: actions.editScript)
                Button("Catch Me Up  ⌃⌥C", action: copilot.catchUp)
                Button("Live Transcript…", action: actions.transcript)
                Button("New Meeting (clear transcript)", action: copilot.newMeeting)
                Divider()
                Button("All Shortcuts  ⌃⌥/") { copilot.showingHelp.toggle() }
                Button("Welcome Guide…", action: actions.welcome)
                Button("Settings…  ⌃⌥,", action: actions.settings)
                Button("Check for Updates…") { Updates.shared.checkNow() }
                Divider()
                Button("Hide Panel  ⌃⌥Space", action: actions.hide)
                Button("Quit TeleNotch") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More: script, shortcuts, settings")
            Button(action: actions.hide) { Image(systemName: "chevron.up") }
                .help("Hide the notch (⌃⌥Space brings it back)")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 14)
    }

    // MARK: Bottom hint bar: the shortcuts that make sense right now

    private var hints: some View {
        let items: [(String, String)]
        if copilot.showingHelp {
            items = [("⌃⌥/", "Close")]
        } else if copilot.showingAnswer {
            items = copilot.streaming
                ? [("⌃⌥P", "Back to script"), ("⌃⌥/", "Shortcuts")]
                : [("⌃⌥↩", "Back to script"), ("⌃⌥C", "Catch up"), ("⌃⌥/", "Shortcuts")]
        } else if teleprompter.isEmpty {
            items = copilot.listening
                ? [("⌃⌥↩", "Answer for me"), ("⌃⌥C", "Catch up"), ("⌃⌥E", "Add a script"), ("⌃⌥Space", "Hide")]
                : [("⌃⌥E", "Add a script"), ("⌃⌥L", "Listen"), ("⌃⌥Space", "Hide"), ("⌃⌥/", "Shortcuts")]
        } else if !copilot.listening {
            items = [("⌃⌥P", teleprompter.playing ? "Pause" : "Play"), ("⌃⌥↑↓", "Speed"), ("⌃⌥L", "Listen"),
                     ("⌃⌥Space", "Hide"), ("⌃⌥/", "Shortcuts")]
        } else {
            items = [("⌃⌥↩", "Answer for me"), ("⌃⌥C", "Catch up"), ("⌃⌥P", teleprompter.playing ? "Pause" : "Play"),
                     ("⌃⌥Space", "Hide"), ("⌃⌥/", "Shortcuts")]
        }
        return HStack(spacing: 14) {
            ForEach(items, id: \.1) { k, label in
                HStack(spacing: 4) {
                    Text(k).fontWeight(.semibold).foregroundStyle(.white.opacity(0.75))
                    Text(label).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }

    // MARK: Message banner

    private func banner(_ b: Banner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: b.kind == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(b.kind == .error ? .red : b.kind == .warning ? .orange : .blue)
            Text(b.text).font(.system(size: 12, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if b.action != nil {
                Button(b.actionTitle) { copilot.performBannerAction() }.controlSize(.small)
            }
            Button { copilot.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.16)))
    }

    // MARK: Content

    private var script: some View {
        GeometryReader { geo in
            Text(teleprompter.script)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineSpacing(fontSize * 0.25)
                .frame(width: geo.size.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { t in
                    Color.clear.onAppear { teleprompter.contentHeight = t.size.height }
                        .onChange(of: t.size.height) { _, h in teleprompter.contentHeight = h }
                })
                .offset(y: geo.size.height * 0.15 - teleprompter.offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                             .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onAppear { teleprompter.viewportHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, h in teleprompter.viewportHeight = h }
        }
        .scaleEffect(x: mirror ? -1 : 1, y: 1)
    }

    /// First launch, or the script was cleared: one obvious thing to do.
    /// Not listening → add a script (the teleprompter is the main feature); in a meeting → get an answer.
    private var emptyState: some View {
        VStack(spacing: 8) {
            if copilot.listening {
                Text("Listening to the meeting").font(.system(size: 17, weight: .semibold))
                Button(action: copilot.answer) {
                    Label("Answer for me  ⌃⌥↩", systemImage: "text.bubble.fill")
                }
                .buttonStyle(NotchPrimaryButton())
                Text("Press it when someone asks you something.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
            } else {
                Button(action: actions.editScript) {
                    Label("Paste your script  ⌃⌥E", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(NotchPrimaryButton())
                Button(action: copilot.toggleListening) {
                    Text("In a meeting? Press ⌃⌥L to listen.")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var answer: some View {
        // Answers start at the top so you can begin reading the first line while the rest streams in.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                if let err = copilot.error {
                    Text(err).font(.system(size: 14)).foregroundStyle(.orange)
                }
                Text(copilot.answerText.isEmpty && copilot.streaming ? "Thinking…" : copilot.answerText)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(copilot.answerText.isEmpty ? .secondary : .primary)
                    .lineSpacing(fontSize * 0.2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 4)
        }
    }

    private var help: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(HotKeyAction.allCases, id: \.rawValue) { a in
                    HStack(spacing: 8) {
                        Text(a.shortcut).font(.system(size: 12, weight: .bold)).frame(width: 64, alignment: .leading)
                        Text(a.label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Primary button in the notch

struct NotchPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Capsule())
    }
}

// MARK: - Teal glow

/// Soft teal light sitting behind the text, slowly drifting and breathing so the panel feels alive.
struct TealGlow: View {
    let topInset: CGFloat
    var intensity: Double = 1
    @State private var drift = false
    @State private var breathe = false

    static let teal = Color(red: 0.08, green: 0.72, blue: 0.65)
    static let tealLight = Color(red: 0.55, green: 0.98, blue: 0.9)

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let textH = max(40, g.size.height - topInset - 22)       // the area the words sit in
            let center = CGPoint(x: w / 2, y: topInset + textH * 0.5)
            ZStack {
                // Main pool of light, centred behind the words
                Ellipse()
                    .fill(RadialGradient(colors: [Self.teal.opacity(0.58 * intensity), Self.teal.opacity(0.2 * intensity), .clear],
                                         center: .center, startRadius: 0, endRadius: w * 0.34))
                    .frame(width: w * 0.78, height: textH * 1.05)
                    .scaleEffect(breathe ? 1.08 : 0.94)
                    .opacity(breathe ? 1 : 0.75)
                    .offset(x: drift ? w * 0.07 : -w * 0.07)
                    .position(center)
                // A second, lighter pool drifting the other way for some depth
                Ellipse()
                    .fill(RadialGradient(colors: [Self.tealLight.opacity(0.22 * intensity), .clear],
                                         center: .center, startRadius: 0, endRadius: w * 0.2))
                    .frame(width: w * 0.42, height: textH * 0.7)
                    .offset(x: drift ? -w * 0.12 : w * 0.12, y: breathe ? -6 : 6)
                    .position(center)
            }
            .blur(radius: 18)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) { drift = true }
            withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) { breathe = true }
        }
        .animation(.easeInOut(duration: 0.6), value: intensity)
    }
}

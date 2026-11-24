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
/// Hover is handled here in AppKit and never handed to SwiftUI: SwiftUI's hover hit-testing crashed the
/// app (EXC_BAD_ACCESS in HoverEventDispatcher) when the pointer entered the panel while its content changed.
final class ClickThroughHostingView<V: View>: NSHostingView<V> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseMoved(with event: NSEvent) {}
}

/// What the panel's buttons and menu can do.
struct PanelActions {
    var editScript: () -> Void
    var settings: () -> Void
    var transcript: () -> Void
    var welcome: () -> Void
    var hide: () -> Void
}

/// Whether the panel is open. Drives the grow-out-of-the-notch animation.
final class PanelState: ObservableObject {
    @Published var open: Bool
    init(open: Bool = false) { self.open = open }
}

@MainActor
final class NotchPanel {
    private var panel: NotchPanelWindow?
    private var host: ClickThroughHostingView<PanelView>?
    private let state = PanelState()
    private var closeWork: DispatchWorkItem?
    private let teleprompter: Teleprompter
    private let copilot: Copilot
    private let actions: PanelActions
    /// Open (or opening). A panel that's mid-way through closing counts as hidden, so toggling reopens it.
    var isVisible: Bool { (panel?.isVisible ?? false) && state.open }
    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let closeAnimation = Animation.spring(response: 0.3, dampingFraction: 0.95)

    init(teleprompter: Teleprompter, copilot: Copilot, actions: PanelActions) {
        self.teleprompter = teleprompter
        self.copilot = copilot
        self.actions = actions
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isVisible == true { self?.layout() } }
        }
    }

    func toggle() { isVisible ? hide() : show() }

    /// Grows out of the notch: the window appears with the panel the size of the notch, then springs open.
    func show() {
        closeWork?.cancel(); closeWork = nil
        let p = panel ?? makePanel()
        panel = p
        if p.isVisible {
            withAnimation(Self.openAnimation) { state.open = true }
        } else {
            state.open = false
            layout()
            p.orderFrontRegardless()
            DispatchQueue.main.async { withAnimation(Self.openAnimation) { self.state.open = true } }
        }
        // The window shadow follows the panel's shape; refresh it once the spring settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in self?.panel?.invalidateShadow() }
    }

    /// Shrinks back into the notch, then removes the window.
    func hide() {
        guard let p = panel, p.isVisible else { return }
        teleprompter.hover(false)
        withAnimation(Self.closeAnimation) { state.open = false }
        p.invalidateShadow()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.state.open else { return }
            self.panel?.orderOut(nil)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
    }

    /// Re-applies size settings (called when preferences change).
    func layout() {
        guard let p = panel, let notch = Notch.current() else { return }
        // The window is wider than the panel by the curved "ears" that join it to the top of the screen.
        let width = max(Prefs.panelWidth, notch.rect.width + 160) + 2 * PanelView.ear
        let topInset = notch.rect.height
        let height = Prefs.panelHeight + topInset
        let sf = notch.screen.frame
        var f = NSRect(x: notch.rect.midX - width / 2, y: sf.maxY - height, width: width, height: height)
        f.origin.x = min(max(f.minX, sf.minX + 4), sf.maxX - f.width - 4)
        p.setFrame(f, display: true)
        let view = PanelView(teleprompter: teleprompter, copilot: copilot, state: state, actions: actions,
                             topInset: topInset, notchWidth: notch.rect.width)
        // Keep one hosting view and update it: swapping it out while the pointer is over the panel
        // left AppKit's tooltip tracking pointing at freed views, which crashed the app.
        if let host { host.rootView = view } else {
            let h = ClickThroughHostingView(rootView: view)
            h.onHover = { [weak self] inside in self?.pointerInside(inside) }
            host = h
            p.contentView = h
        }
    }

    /// Pointer on the panel pauses the script; moving away picks it up again.
    private func pointerInside(_ inside: Bool) {
        teleprompter.hover(inside && state.open && !copilot.showingAnswer && !copilot.showingHelp)
    }

    private func makePanel() -> NotchPanelWindow {
        let p = NotchPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.isMovable = false
        // Ask macOS to leave this window out of screenshots, recordings and screen shares.
        // (TELENOTCH_CAPTURABLE=1 lets screenshots see it, for testing and docs.)
        p.sharingType = ProcessInfo.processInfo.environment["TELENOTCH_CAPTURABLE"] == nil ? .none : .readOnly
        return p
    }
}

// MARK: - Panel content

struct PanelView: View {
    @ObservedObject var teleprompter: Teleprompter
    @ObservedObject var copilot: Copilot
    @ObservedObject var state: PanelState
    let actions: PanelActions
    let topInset: CGFloat
    let notchWidth: CGFloat
    @AppStorage("fontSize") private var fontSize = 22.0
    @AppStorage("mirror") private var mirror = false
    @AppStorage("showHints") private var showHints = true
    @AppStorage("glow") private var glow = true

    /// Radius of the curves where the panel meets the top edge of the screen.
    static let ear: CGFloat = 10

    private var shape: NotchShape {
        NotchShape(progress: state.open ? 1 : 0, notchWidth: notchWidth, notchHeight: topInset, ear: Self.ear)
    }

    var body: some View {
        content
            .padding(.horizontal, Self.ear)
            .opacity(state.open ? 1 : 0)
            .scaleEffect(state.open ? 1 : 0.92, anchor: .top)
            .animation(state.open ? .easeOut(duration: 0.22).delay(0.1) : .easeIn(duration: 0.1), value: state.open)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(panelBackground)
            .clipShape(shape)
            .contentShape(shape)
            .environment(\.colorScheme, .dark)
    }

    private var content: some View {
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
        .animation(.easeOut(duration: 0.15), value: copilot.banner)
    }

    // MARK: Background: black, with teal light rising from the bottom edge behind the text

    private var panelBackground: some View {
        shape.fill(Color.black)
            .overlay {
                if glow {
                    // Brighter while an answer is being written.
                    TealGlow(topInset: topInset, intensity: copilot.streaming ? 1.35 : 1)
                        .padding(.horizontal, Self.ear)
                        .opacity(state.open ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: Top bar: controls either side of the notch

    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
            // Left of the notch: listening + playback
            Button(action: copilot.toggleListening) {
                HStack(spacing: 5) {
                    if copilot.starting { Spinner() }
                    else { Circle().fill(copilot.listening ? Color.red : Color.gray.opacity(0.6)).frame(width: 7, height: 7) }
                    Text(copilot.listening ? "Listening" : copilot.starting ? "Starting…" : "Listen")
                }
            }
            if !copilot.showingAnswer && !copilot.showingHelp && !teleprompter.isEmpty {
                Button(action: teleprompter.togglePlay) { Image(systemName: teleprompter.playing ? "pause.fill" : "play.fill") }
                Text("\(Int(teleprompter.wpm)) wpm").monospacedDigit().foregroundStyle(.secondary)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notchWidth + 16)  // the notch itself
            HStack(spacing: 10) {
            // Right of the notch: answer + menu
            if copilot.showingAnswer {
                if copilot.streaming { Spinner() }
                Text(copilot.answerTitle).foregroundStyle(.secondary)
                Button(action: copilot.dismissAnswer) { Label("Script", systemImage: "arrow.uturn.backward") }
            } else if copilot.showingHelp {
                Button { copilot.showingHelp = false } label: { Label("Done", systemImage: "checkmark") }
            } else {
                Button(action: copilot.answer) {
                    Label("Answer", systemImage: "text.bubble.fill")
                }
            }
            Button(action: showMenu) { Image(systemName: "ellipsis.circle") }
            Button(action: actions.hide) { Image(systemName: "chevron.up") }
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
        } else if teleprompter.pausedByHover {
            items = [("⏸", "Paused while your pointer is on the notch. Move it away to continue")]
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
        // Plain stacks, no ScrollView: native scroll views inside the panel crashed SwiftUI's hit-testing.
        Group {
            VStack(alignment: .leading, spacing: 6) {
                if let err = copilot.error {
                    Text(err).font(.system(size: 14)).foregroundStyle(.orange)
                }
                Text(copilot.answerText.isEmpty && copilot.streaming ? "Thinking…" : copilot.answerText)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(copilot.answerText.isEmpty ? .secondary : .primary)
                    .lineSpacing(fontSize * 0.2)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    /// The ⋯ menu, as a standard AppKit menu. A SwiftUI Menu embeds a native pop-up button, which crashed
    /// SwiftUI's hit-testing when the pointer met the panel while it redrew.
    private func showMenu() {
        let m = ClosureMenu()
        m.add("Edit Script…  ⌃⌥E", actions.editScript)
        m.add("Catch Me Up  ⌃⌥C", copilot.catchUp)
        m.add("Live Transcript…", actions.transcript)
        m.add("New Meeting (clear transcript)", copilot.newMeeting)
        m.menu.addItem(.separator())
        m.add("All Shortcuts  ⌃⌥/") { copilot.showingHelp.toggle() }
        m.add("Welcome Guide…", actions.welcome)
        m.add("Settings…  ⌃⌥,", actions.settings)
        m.add("Check for Updates…") { Updates.shared.checkNow() }
        m.menu.addItem(.separator())
        m.add("Hide Panel  ⌃⌥Space", actions.hide)
        m.add("Quit TeleNotch") { NSApp.terminate(nil) }
        m.popUpAtPointer()
    }

    private var help: some View {
        Group {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }
}

/// A small spinner drawn by SwiftUI. ProgressView is a native NSProgressIndicator on macOS, and
/// adding/removing it while the pointer was over the panel crashed SwiftUI's hit-testing.
struct Spinner: View {
    @State private var spin = false
    var body: some View {
        Circle().trim(from: 0, to: 0.7)
            .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

/// An NSMenu whose items run closures.
@MainActor
final class ClosureMenu: NSObject {
    let menu = NSMenu()
    private var actions: [() -> Void] = []
    func add(_ title: String, _ action: @escaping () -> Void) {
        let i = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        i.target = self; i.tag = actions.count
        actions.append(action); menu.addItem(i)
    }
    @objc private func run(_ sender: NSMenuItem) { actions[sender.tag]() }
    func popUpAtPointer() {
        // popUp blocks until the menu closes, which keeps self (the items' target) alive meanwhile.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Panel shape

/// The panel's outline: hangs from the top edge of the screen with curved "ears" flaring into it,
/// like the hardware notch, and rounded bottom corners. At progress 0 it's the size of the notch;
/// at 1 it fills the window, so animating progress grows the panel out of the notch.
struct NotchShape: Shape {
    var progress: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let ear: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, progress)
        let fullW = rect.width - 2 * ear
        let w = notchWidth + (fullW - notchWidth) * t
        let h = max(notchHeight, notchHeight + (rect.height - notchHeight) * t)
        let r = min(10 + 12 * min(t, 1), h / 2, w / 2)   // bottom corners: notch-like when closed, softer when open
        let e = min(ear, h - r)                            // ears
        let x0 = rect.midX - w / 2, x1 = rect.midX + w / 2
        let k: CGFloat = 0.552                             // circle-like cubic curves
        var p = Path()
        p.move(to: CGPoint(x: x0 - e, y: 0))
        p.addCurve(to: CGPoint(x: x0, y: e), control1: CGPoint(x: x0 - e + e * k, y: 0), control2: CGPoint(x: x0, y: e - e * k))
        p.addLine(to: CGPoint(x: x0, y: h - r))
        p.addCurve(to: CGPoint(x: x0 + r, y: h), control1: CGPoint(x: x0, y: h - r + r * k), control2: CGPoint(x: x0 + r - r * k, y: h))
        p.addLine(to: CGPoint(x: x1 - r, y: h))
        p.addCurve(to: CGPoint(x: x1, y: h - r), control1: CGPoint(x: x1 - r + r * k, y: h), control2: CGPoint(x: x1, y: h - r + r * k))
        p.addLine(to: CGPoint(x: x1, y: e))
        p.addCurve(to: CGPoint(x: x1 + e, y: 0), control1: CGPoint(x: x1, y: e - e * k), control2: CGPoint(x: x1 + e - e * k, y: 0))
        p.closeSubpath()
        return p
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

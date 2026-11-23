// TeleNotch: a teleprompter that lives in your MacBook's notch, with a meeting copilot.
// Press ⌃⌥↩ when you're put on the spot and Claude writes, in your voice, what to say next,
// based on what it heard from your mic and your Mac's audio.

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let teleprompter = Teleprompter()
    let copilot = Copilot()
    lazy var panel: NotchPanel = NotchPanel(teleprompter: teleprompter, copilot: copilot, actions: PanelActions(
        editScript: { [weak self] in self?.showScript() },
        settings: { [weak self] in self?.showSettings() },
        transcript: { [weak self] in self?.showTranscript() },
        welcome: { [weak self] in self?.showWelcome() },
        hide: { [weak self] in self?.panel.hide() }))
    var hotKeys: HotKeys?
    var statusItem: NSStatusItem?
    let settingsWindow = WindowBox(), scriptWindow = WindowBox(), transcriptWindow = WindowBox(), welcomeWindow = WindowBox()
    private var lastSize: [Double] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        Prefs.register()
        if CommandLine.arguments.contains("--selftest") {
            Task { await SelfTest.run(args: CommandLine.arguments, copilot: copilot) }
            return
        }
        quitOtherCopies()
        installEditMenu()
        MoveToApplications.offerIfNeeded()
        Updates.shared.start()
        copilot.onNeedsPanel = { [weak self] in if self?.panel.isVisible == false { self?.panel.show() } }
        copilot.confirmConsent = { [weak self] in self?.askConsent() ?? true }
        copilot.onBannerAction = { [weak self] action in
            switch action {
            case .openSettings: self?.showSettings()
            case .openMicPrivacy: Privacy.open(.microphone)
            case .openAudioPrivacy: Privacy.open(.systemAudio)
            case .openWelcome: self?.showWelcome()
            }
        }
        hotKeys = HotKeys { [weak self] in self?.handle($0) }
        makeStatusItem()
        lastSize = sizePrefs()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = self.sizePrefs()
                if s != self.lastSize { self.lastSize = s; self.panel.layout() }
            }
        }
        panel.show()
        let args = CommandLine.arguments
        if args.contains("--welcome") || !Prefs.onboarded { showWelcome() }
        else if args.contains("--settings") { showSettings() }
        else if Keychain.apiKey == nil { copilot.notify("Add your Anthropic API key to get answers.", .warning, action: .openSettings) }
        if args.contains("--play") { teleprompter.play() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return false
    }

    /// Menu-bar-only apps have no menu bar of their own, so ⌘V/⌘C/⌘X/⌘A/⌘Z would do nothing in text fields.
    /// An (invisible) main menu with the standard Edit items makes those shortcuts work.
    /// Only one TeleNotch at a time: two copies (say, one in Applications and one in Downloads) would each draw
    /// a notch panel in the same spot and fight over the shortcuts, so hiding one leaves the other showing.
    /// The copy just opened wins, which is what you want after an update or a move to Applications.
    private func quitOtherCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        // Wait briefly so their shortcuts are free before we register ours.
        let deadline = Date().addingTimeInterval(2)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit TeleNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func sizePrefs() -> [Double] { [Prefs.panelWidth, Prefs.panelHeight] }

    func handle(_ a: HotKeyAction) {
        switch a {
        case .togglePanel: panel.toggle()
        case .playPause:
            if copilot.showingHelp { copilot.showingHelp = false }
            else if copilot.showingAnswer { copilot.dismissAnswer() }
            else if teleprompter.isEmpty { showScript() }   // nothing to play yet: open the editor
            else { teleprompter.togglePlay() }
        case .faster: teleprompter.changeSpeed(by: 10)
        case .slower: teleprompter.changeSpeed(by: -10)
        case .back: teleprompter.back()
        case .answer:
            // Pressing it again while an answer is showing goes back to the script.
            if copilot.showingAnswer && !copilot.streaming { copilot.dismissAnswer() } else { copilot.answer() }
        case .catchUp: copilot.catchUp()
        case .listen: copilot.toggleListening()
        case .editScript: showScript()
        case .help:
            copilot.showingHelp.toggle()
            if copilot.showingHelp && !panel.isVisible { panel.show() }
        case .settings: showSettings()
        }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "TeleNotch")
        let m = NSMenu()
        func add(_ title: String, _ action: Selector, _ hk: HotKeyAction? = nil) {
            let i = NSMenuItem(title: hk.map { "\(title)    \($0.shortcut)" } ?? title, action: action, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        add("Show / Hide Panel", #selector(menuToggle), .togglePanel)
        add("Play / Pause Script", #selector(menuPlay), .playPause)
        add("Restart Script", #selector(menuRestart))
        add("Edit Script…", #selector(showScript), .editScript)
        m.addItem(.separator())
        add("Start / Stop Listening", #selector(menuListen), .listen)
        add("Answer for Me", #selector(menuAnswer), .answer)
        add("Catch Me Up", #selector(menuCatchUp), .catchUp)
        add("Live Transcript…", #selector(showTranscript))
        add("New Meeting (clear transcript)", #selector(menuNewMeeting))
        m.addItem(.separator())
        add("All Shortcuts", #selector(menuHelp), .help)
        add("Welcome Guide…", #selector(showWelcome))
        add("Settings…", #selector(showSettings), .settings)
        add("Check for Updates…", #selector(checkUpdates))
        m.addItem(NSMenuItem(title: "Quit TeleNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = m
        statusItem = item
    }

    @objc func menuToggle() { panel.toggle() }
    @objc func menuPlay() { teleprompter.togglePlay() }
    @objc func menuRestart() { teleprompter.restart() }
    @objc func menuListen() { copilot.toggleListening() }
    @objc func menuAnswer() { copilot.answer() }
    @objc func menuCatchUp() { copilot.catchUp() }
    @objc func menuNewMeeting() { copilot.newMeeting() }
    @objc func menuHelp() { handle(.help) }
    @objc func checkUpdates() { Updates.shared.checkNow() }
    @objc func showSettings() {
        settingsWindow.show(title: "TeleNotch Settings", SettingsView(copilot: copilot, openWelcome: { [weak self] in self?.showWelcome() }))
    }
    @objc func showWelcome() {
        welcomeWindow.show(title: "Welcome to TeleNotch", resizable: false,
                           WelcomeView(copilot: copilot, teleprompter: teleprompter, onFinish: { [weak self] in
                               Prefs.onboarded = true
                               self?.welcomeWindow.close()
                               self?.copilot.notify("You're set. Press ⌃⌥L when your meeting starts, ⌃⌥/ for all shortcuts.")
                           }))
    }

    /// Shown the first time you start listening, unless you already confirmed it in the guide.
    private func askConsent() -> Bool {
        let a = NSAlert()
        a.messageText = "Let people know you're transcribing"
        a.informativeText = "TeleNotch will write down what everyone in this call says. In many places, recording or transcribing a conversation requires everyone's consent. A red dot in the notch shows while it's listening."
        a.addButton(withTitle: "Start Listening")
        a.addButton(withTitle: "Cancel")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't remind me again"
        NSApp.activate(ignoringOtherApps: true)
        let ok = a.runModal() == .alertFirstButtonReturn
        if ok && a.suppressionButton?.state == .on { Prefs.consentAcknowledged = true }
        return ok
    }
    @objc func showScript() { scriptWindow.show(title: "Script", ScriptEditorView(teleprompter: teleprompter)) }
    @objc func showTranscript() {
        transcriptWindow.show(title: "Live Transcript", TranscriptView(copilot: copilot, transcript: copilot.transcript))
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

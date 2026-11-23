import AppKit
import Carbon.HIToolbox
import Security

// MARK: - Preferences

enum CopilotMode: String, CaseIterable, Identifiable {
    case meeting, presentation
    var id: String { rawValue }
    var label: String { self == .meeting ? "Meeting / debate" : "Presentation Q&A" }
}

enum Prefs {
    static let d = UserDefaults.standard
    static let models = [("claude-opus-5-5", "Claude Opus 5.5 (best answers)"),
                         ("claude-sonnet-5-5", "Claude Sonnet 5.5 (faster)"),
                         ("claude-haiku-5-5", "Claude Haiku 5.5 (fastest, cheapest)")]

    static func register() {
        d.register(defaults: [
            "script": "",
            "fontSize": 22.0, "wpm": 140.0, "panelWidth": 600.0, "panelHeight": 190.0, "mirror": false,
            "model": "claude-opus-5-5", "mode": CopilotMode.meeting.rawValue,
            "aboutMe": "", "meetingContext": "", "summaryInterval": 45.0, "menuBarIcon": true,
            "showHints": true, "glow": true, "onboarded": false, "consentAcknowledged": false,
        ])
        // Versions before 0.2.3 saved a sample script; start those people with an empty one instead.
        if d.string(forKey: "script")?.hasPrefix("Paste your script here.") == true { d.removeObject(forKey: "script") }
    }
    static var script: String { get { d.string(forKey: "script") ?? "" } set { d.set(newValue, forKey: "script") } }
    static var fontSize: Double { d.double(forKey: "fontSize") }
    /// Scroll speed in words per minute (people speak at roughly 130–160).
    static var wpm: Double { get { d.double(forKey: "wpm") } set { d.set(min(max(newValue, 60), 300), forKey: "wpm") } }
    static var panelWidth: Double { d.double(forKey: "panelWidth") }
    static var panelHeight: Double { d.double(forKey: "panelHeight") }
    static var mirror: Bool { d.bool(forKey: "mirror") }
    static var model: String { d.string(forKey: "model") ?? "claude-opus-5-5" }
    static var mode: CopilotMode { CopilotMode(rawValue: d.string(forKey: "mode") ?? "") ?? .meeting }
    static var aboutMe: String { d.string(forKey: "aboutMe") ?? "" }
    static var meetingContext: String { d.string(forKey: "meetingContext") ?? "" }
    static var summaryInterval: Double { max(15, d.double(forKey: "summaryInterval")) }
    static var showHints: Bool { d.bool(forKey: "showHints") }
    static var onboarded: Bool { get { d.bool(forKey: "onboarded") } set { d.set(newValue, forKey: "onboarded") } }
    static var consentAcknowledged: Bool {
        get { d.bool(forKey: "consentAcknowledged") } set { d.set(newValue, forKey: "consentAcknowledged") }
    }
}

// MARK: - API key in the Keychain

enum Keychain {
    private static let service = "app.telenotch.TeleNotch", account = "anthropic-api-key"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static var apiKey: String? {
        var q = base; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }
    static func setAPIKey(_ key: String) {
        SecItemDelete(base as CFDictionary)
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        var q = base; q[kSecValueData as String] = Data(k.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Global hotkeys (fixed set for now)

enum HotKeyAction: UInt32, CaseIterable {
    case togglePanel = 1, playPause, faster, slower, back, answer, catchUp, listen, editScript, help, settings

    var key: (code: Int, mods: Int) {
        let co = controlKey | optionKey
        switch self {
        case .togglePanel: return (kVK_Space, co)
        case .playPause: return (kVK_ANSI_P, co)
        case .faster: return (kVK_UpArrow, co)
        case .slower: return (kVK_DownArrow, co)
        case .back: return (kVK_LeftArrow, co)
        case .answer: return (kVK_Return, co)
        case .catchUp: return (kVK_ANSI_C, co)
        case .listen: return (kVK_ANSI_L, co)
        case .editScript: return (kVK_ANSI_E, co)
        case .help: return (kVK_ANSI_Slash, co)
        case .settings: return (kVK_ANSI_Comma, co)
        }
    }
    var label: String {
        switch self {
        case .togglePanel: return "Show / hide the notch panel"
        case .playPause: return "Play / pause the script"
        case .faster: return "Scroll faster"
        case .slower: return "Scroll slower"
        case .back: return "Jump back a few lines"
        case .answer: return "Answer for me (what do I say?)"
        case .catchUp: return "Catch me up (what's going on?)"
        case .listen: return "Start / stop listening"
        case .editScript: return "Edit script"
        case .help: return "Show all shortcuts"
        case .settings: return "Settings"
        }
    }
    var shortcut: String {
        let (code, mods) = key
        var t = ""
        if mods & controlKey != 0 { t += "⌃" }
        if mods & optionKey != 0 { t += "⌥" }
        if mods & shiftKey != 0 { t += "⇧" }
        if mods & cmdKey != 0 { t += "⌘" }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_LeftArrow: "←", kVK_ANSI_P: "P", kVK_ANSI_C: "C", kVK_ANSI_L: "L", kVK_ANSI_E: "E",
                                    kVK_ANSI_Slash: "/", kVK_ANSI_Comma: ","]
        return t + (names[code] ?? "?")
    }
}

final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private static var handler: ((HotKeyAction) -> Void)?

    init(handler: @escaping (HotKeyAction) -> Void) {
        HotKeys.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let a = HotKeyAction(rawValue: id.id) { DispatchQueue.main.async { HotKeys.handler?(a) } }
            return noErr
        }, 1, &spec, nil, nil)
        for a in HotKeyAction.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x544E_4F54), id: a.rawValue) // "TNOT"
            let st = RegisterEventHotKey(UInt32(a.key.code), UInt32(a.key.mods), id, GetApplicationEventTarget(), 0, &ref)
            if st != noErr { NSLog("TN hotkey \(a.shortcut) NOT registered (\(st))") }
            if let ref { refs.append(ref) }
        }
    }
}

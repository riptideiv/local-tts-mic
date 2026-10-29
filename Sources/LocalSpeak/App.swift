import SwiftUI
import AppKit
import Carbon
import Combine

@main struct LocalSpeakApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class TypingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var mainWindow: NSWindow!
    private var panel: TypingPanel!
    private var statusItem: NSStatusItem!
    private var previousApp: NSRunningApplication?
    private var eventHandler: EventHandlerRef?
    private var overlayRef: EventHotKeyRef?
    private var stopRef: EventHotKeyRef?
    private var settingsSubscription: AnyCancellable?
    private var registered: [Hotkey] = []
    private var localKeys: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--queue-test"), CommandLine.arguments.count > index + 1 {
            NSApp.setActivationPolicy(.accessory)
            QueueStressProbe.run(report: CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--loopback-test"), CommandLine.arguments.count > index + 2 {
            NSApp.setActivationPolicy(.accessory)
            LoopbackProbe.run(source: CommandLine.arguments[index + 1], report: CommandLine.arguments[index + 2], preview: CommandLine.arguments.contains("--preview"), reset: CommandLine.arguments.contains("--reset-between-messages"), monitoring: CommandLine.arguments.contains("--monitor"))
            return
        }
        NSApp.setActivationPolicy(.regular)
        let captureIndex = CommandLine.arguments.firstIndex(of: "--capture-demo")
        let capturing = captureIndex != nil
        model = AppModel(startAutomatically: !capturing, persistChanges: !capturing)
        if capturing {
            model.settings = Settings()
            model.draft = "Hello! My voice is running locally on this Mac."
            model.engineStatus = "Interface preview · speech disabled"
            NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--capture-dark") ? .darkAqua : .aqua)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        if capturing, CommandLine.arguments.contains("--capture-compact") { window.setContentSize(NSSize(width: 820, height: 620)) }
        window.title = "Local TTS Mic"
        window.minSize = NSSize(width: 820, height: 620)
        window.isReleasedWhenClosed = false
        let mainContent = NSHostingView(rootView: MainView(model: model))
        // AppKit owns this resizable window's bounds. Do not let SwiftUI's
        // ideal-size probe expand it to the height of unconstrained help text.
        mainContent.sizingOptions = []
        window.contentView = mainContent
        window.center(); mainWindow = window
        buildMenu()
        panel = TypingPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 206), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: OverlayView(model: model, dismiss: { [weak self] in self?.hideOverlay() }))
        model.showOverlay = { [weak self] in self?.toggleOverlay() }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, raw in
            guard let event, let raw else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(raw).takeUnretainedValue()
            let keyID = id.id
            DispatchQueue.main.async {
                if keyID == 1 { delegate.toggleOverlay() }
                else if keyID == 2 { delegate.model.stopAll() }
            }
            return noErr
        }, 1, &spec, pointer, &eventHandler)
        settingsSubscription = model.$settings.sink { [weak self] settings in self?.registerHotkeys(settings) }
        // Targeted AppKit key events (and some assistive input tools) don't pass
        // through the WindowServer hotkey registry. Handle those while focused.
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !(NSApp.keyWindow?.firstResponder is ShortcutField) else { return event }
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            func matches(_ key: Hotkey) -> Bool {
                var expected: NSEvent.ModifierFlags = []
                if key.modifiers & UInt32(controlKey) != 0 { expected.insert(.control) }
                if key.modifiers & UInt32(optionKey) != 0 { expected.insert(.option) }
                if key.modifiers & UInt32(shiftKey) != 0 { expected.insert(.shift) }
                if key.modifiers & UInt32(cmdKey) != 0 { expected.insert(.command) }
                return UInt32(event.keyCode) == key.keyCode && flags == expected
            }
            if matches(self.model.settings.overlayHotkey) { self.toggleOverlay(); return nil }
            if matches(self.model.settings.stopHotkey) { self.model.stopAll(); return nil }
            return event
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Local TTS Mic")
        let menu = NSMenu()
        menu.addItem(withTitle: "Type to speak", action: #selector(showTyping), keyEquivalent: "")
        menu.addItem(withTitle: "Open Local TTS Mic", action: #selector(showMain), keyEquivalent: "")
        menu.addItem(withTitle: "Stop and clear queue", action: #selector(stopSpeaking), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Local TTS Mic", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        mainWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let index = captureIndex, CommandLine.arguments.count > index + 1 {
            let destination = CommandLine.arguments[index + 1]
            if CommandLine.arguments.contains("--capture-live-preview") {
                model.startEngine()
                Task { [weak self] in
                    var submitted = false
                    for _ in 0..<960 {
                        guard let self else { return }
                        if self.model.ready && !submitted {
                            submitted = self.model.submit(text: "Hello! My voice is running locally on this Mac.", delivery: .preview)
                        }
                        if submitted && self.model.jobs.last?.status == "Done" {
                            self.captureWindow(to: destination)
                            return
                        }
                        if self.model.error != nil {
                            fputs("Live preview failed: \(self.model.error ?? "Unknown error")\n", stderr)
                            NSApp.terminate(nil)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    fputs("Live preview timed out\n", stderr)
                    NSApp.terminate(nil)
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.captureWindow(to: destination) }
            }
        }
    }

    private func captureWindow(to destination: String) {
        guard let view = mainWindow.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            let url = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LocalError("Cannot capture preview") }
            try data.write(to: url)
        } catch { fputs("Preview capture failed: \(error)\n", stderr) }
        NSApp.terminate(nil)
    }

    private func buildMenu() {
        let menu = NSMenu(), appMenu = NSMenu(), appItem = NSMenuItem()
        appItem.submenu = appMenu; menu.addItem(appItem)
        appMenu.addItem(withTitle: "About Local TTS Mic", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Local TTS Mic", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Local TTS Mic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit"), editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit; menu.addItem(editItem)
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        NSApp.mainMenu = menu
    }

    private func registerHotkeys(_ settings: Settings) {
        let shortcuts = [settings.overlayHotkey, settings.stopHotkey]
        guard shortcuts != registered else { return }
        if let overlayRef { UnregisterEventHotKey(overlayRef) }
        if let stopRef { UnregisterEventHotKey(stopRef) }
        overlayRef = nil; stopRef = nil
        registered = shortcuts
        let signature: OSType = 0x4c53504b
        let first = RegisterEventHotKey(shortcuts[0].keyCode, shortcuts[0].modifiers, EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &overlayRef)
        let second = RegisterEventHotKey(shortcuts[1].keyCode, shortcuts[1].modifiers, EventHotKeyID(signature: signature, id: 2), GetApplicationEventTarget(), 0, &stopRef)
        DispatchQueue.main.async { [weak self] in
            self?.model.hotkeyError = first != noErr || second != noErr ? "A shortcut is already in use. Record a different combination in Audio settings." : nil
        }
    }

    @objc private func showTyping() { toggleOverlay() }
    @objc private func showMain() { guard let mainWindow else { return }; mainWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func stopSpeaking() { model.stopAll() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func findComposer(_ view: NSView?) -> ComposerTextView? {
        if let text = view as? ComposerTextView { return text }
        for child in view?.subviews ?? [] { if let found = findComposer(child) { return found } }
        return nil
    }

    private func toggleOverlay() {
        if panel.isVisible { hideOverlay(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + max(50, frame.height * 0.16)))
        }
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, let text = self.findComposer(self.panel.contentView) else { return }
            self.panel.makeFirstResponder(text)
        }
    }

    private func hideOverlay() {
        panel.orderOut(nil)
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp.activate(options: []) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
        if let overlayRef { UnregisterEventHotKey(overlayRef) }
        if let stopRef { UnregisterEventHotKey(stopRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let localKeys { NSEvent.removeMonitor(localKeys) }
    }
}

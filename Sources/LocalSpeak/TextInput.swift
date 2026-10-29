import SwiftUI
import AppKit
import Carbon

final class ComposerTextView: NSTextView {
    var submit: (() -> Void)?
    var dismiss: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !event.modifierFlags.contains(.shift), !hasMarkedText() {
            submit?(); return
        }
        if event.keyCode == 53, !hasMarkedText(), let dismiss { dismiss(); return }
        super.keyDown(with: event)
    }
}

struct ComposerInput: NSViewRepresentable {
    @Binding var text: String
    var compact = false
    var onSubmit: () -> Void
    var onDismiss: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let view = ComposerTextView()
        view.isRichText = false; view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isGrammarCheckingEnabled = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: compact ? 19 : 22)
        view.textColor = .labelColor
        view.insertionPointColor = .controlAccentColor
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Message to speak")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        if view.string != text && !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        view.submit = onSubmit; view.dismiss = onDismiss
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerInput
        init(_ parent: ComposerInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
    }
}

final class ShortcutField: NSTextField {
    var onRecord: ((Hotkey) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); stringValue = "Press shortcut…" }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        record(event); return true
    }
    override func keyDown(with event: NSEvent) { record(event) }
    private func record(_ event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f.contains(.control) || f.contains(.option) || f.contains(.command) else {
            stringValue = "Include ⌃, ⌥, or ⌘"; return
        }
        var mods: UInt32 = 0, label = ""
        if f.contains(.control) { mods |= UInt32(controlKey); label += "⌃" }
        if f.contains(.option) { mods |= UInt32(optionKey); label += "⌥" }
        if f.contains(.shift) { mods |= UInt32(shiftKey); label += "⇧" }
        if f.contains(.command) { mods |= UInt32(cmdKey); label += "⌘" }
        let key = [UInt16(49): "Space", 53: "Esc", 36: "Return", 48: "Tab", 51: "Delete"][event.keyCode] ?? (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
        label += key
        onRecord?(Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods, label: label))
        window?.makeFirstResponder(nil)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Hotkey
    func makeNSView(context: Context) -> ShortcutField {
        let field = ShortcutField()
        field.isEditable = false; field.isSelectable = false; field.alignment = .center
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.setAccessibilityLabel("Click to record keyboard shortcut")
        return field
    }
    func updateNSView(_ field: ShortcutField, context: Context) {
        field.stringValue = shortcut.label
        field.onRecord = { shortcut = $0 }
    }
}


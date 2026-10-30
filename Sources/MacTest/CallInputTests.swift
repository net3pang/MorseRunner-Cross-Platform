#if os(macOS)
import AppKit
import XCTest
import MorseRunnerCore
@testable import MorseRunner

@MainActor
final class CallInputTests: XCTestCase {
    func testFocusSelectsEnglishAndRestoresChineseOnLeaving() throws {
        try withCallInput { window, editor in
            let call = try XCTUnwrap(editor.delegate as? NSTextField)
            let otherField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
            window.contentView?.addSubview(otherField)
            XCTAssertTrue(window.makeFirstResponder(otherField))
            let context = try XCTUnwrap(otherField.currentEditor()?.inputContext)
            let originalSource = context.selectedKeyboardInputSource
            defer {
                _ = window.makeFirstResponder(otherField)
                context.selectedKeyboardInputSource = originalSource
                _ = window.makeFirstResponder(nil)
                otherField.removeFromSuperview()
            }
            let chinese = "com.apple.inputmethod.SCIM.ITABC"
            guard context.keyboardInputSources?.contains(chinese) == true else {
                throw XCTSkip("Simplified Chinese Pinyin is not installed")
            }
            context.selectedKeyboardInputSource = chinese
            XCTAssertEqual(context.selectedKeyboardInputSource, chinese)

            XCTAssertTrue(window.makeFirstResponder(call))
            let callContext = try XCTUnwrap(call.currentEditor()?.inputContext)
            XCTAssertTrue(["com.apple.keylayout.ABC", "com.apple.keylayout.US"].contains(
                try XCTUnwrap(callContext.selectedKeyboardInputSource)))

            XCTAssertTrue(window.makeFirstResponder(otherField))
            XCTAssertEqual(context.selectedKeyboardInputSource, chinese,
                           "Leaving the callsign field must restore the previous input method")
        }
    }

    func testCallEditsReachTransmitterAfterReturn() throws {
        try withCallInput { window, editor in
            try typePrefix(in: window)
            try key("\r", 36, in: window)
            try key("b", 11, in: window)
            assertTransmitting("K1AB", editor: editor)
        }
    }

    func testChineseIMEMarkedSuffixReachesTransmitter() throws {
        try withCallInput { window, editor in
            try typePrefix(in: window)
            try key("\r", 36, in: window)
            // This is NSTextInputClient's actual IME preedit protocol. Unlike
            // insertText, setMarkedText does not notify the NSTextField.
            mark("b", in: editor)
            assertTransmitting("K1AB", editor: editor)
            mark("bc", in: editor)
            assertTransmitting("K1ABC", editor: editor)
            XCTAssertTrue(editor.hasMarkedText())
        }
    }

    func testReturnConfirmsPreeditBeforeContinuingCall() throws {
        try withCallInput { window, editor in
            try key("k", 40, in: window)
            try key("1", 18, in: window)
            editor.setMarkedText("a", selectedRange: NSRange(location: 0, length: 1),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            try key("\r", 36, in: window)
            XCTAssertFalse(editor.hasMarkedText(), "Return must end the previous composition")
            XCTAssertEqual(editor.string, "K1A")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
            assertTransmitting("K1A", editor: editor)
            mark("b", in: editor)
            assertTransmitting("K1AB", editor: editor)
            mark("bc", in: editor)
            assertTransmitting("K1ABC", editor: editor)
        }
    }

    func testIMEPreeditCanBeDeletedBeforeItIsSent() throws {
        try withCallInput { window, editor in
            try typePrefix(in: window)
            try key("\r", 36, in: window)
            mark("b", in: editor)
            assertTransmitting("K1AB", editor: editor)
            mark("", in: editor)
            assertTransmitting("K1A", editor: editor)
        }
    }

    private func withCallInput(_ test: (NSWindow, NSTextView) throws -> Void) throws {
        _ = NSApplication.shared
        Settings.call = "VE3NEA"
        Settings.simContest = .wpx
        Settings.wpm = 25
        Settings.callsFromKeyer = false
        let controller = MainWindowController()
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let sim = SimController.shared
        sim.audioBackend = SilentAudioBackend()
        sim.setContest(.wpx)
        sim.run(.pileup)
        defer { sim.stop(); window.close() }

        func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        let call = try XCTUnwrap(fields(in: try XCTUnwrap(window.contentView)).first {
            $0.placeholderString == "Call"
        })
        XCTAssertTrue(window.makeFirstResponder(call))
        let editor = try XCTUnwrap(call.currentEditor() as? NSTextView)
        try test(window, editor)
    }

    private func key(_ characters: String, _ keyCode: UInt16, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        NSApp.sendEvent(event)
    }

    private func typePrefix(in window: NSWindow) throws {
        try key("k", 40, in: window)
        try key("1", 18, in: window)
        try key("a", 0, in: window)
        XCTAssertEqual(SimController.shared.enteredCall, "K1A")
    }

    private func mark(_ text: String, in editor: NSTextView) {
        editor.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func assertTransmitting(_ call: String, editor: NSTextView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(editor.string.uppercased(), call, file: file, line: line)
        XCTAssertEqual(SimController.shared.enteredCall, call, file: file, line: line)
        XCTAssertEqual(Contest.shared?.me.hisCall, call, file: file, line: line)
        XCTAssertEqual(Contest.shared?.me.msgText, call, file: file, line: line)
    }
}
#endif

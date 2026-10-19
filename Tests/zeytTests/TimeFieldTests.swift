import AppKit
import Testing
@testable import zeyt

/// Key handling of the segmented time field (like `type="time"`).
@MainActor
struct TimeFieldTests {
    private func key(_ chars: String, _ code: UInt16 = 0, shift: Bool = false, option: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero,
                         modifierFlags: NSEvent.ModifierFlags().union(shift ? .shift : []).union(option ? .option : []), timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    private func field(_ h: Int, _ m: Int) -> (TimeSegmentView, () -> (Int, Int)?) {
        let v = TimeSegmentView()
        v.hour = h
        v.minute = m
        var committed: (Int, Int)?
        v.onCommit = { committed = ($0, $1) }
        v.onEnter = {}
        _ = v.becomeFirstResponder()
        return (v, { committed })
    }

    private func type(_ v: TimeSegmentView, _ s: String) {
        for c in s { v.keyDown(with: key(String(c))) }
    }

    private let enter: UInt16 = 36, up: UInt16 = 126, down: UInt16 = 125, right: UInt16 = 124, left: UInt16 = 123
    private let tab: UInt16 = 48, backspace: UInt16 = 51, escape: UInt16 = 53

    @Test func typingFourDigitsFillsHourThenMinute() {
        let (v, committed) = field(8, 30)
        type(v, "0915")
        v.keyDown(with: key("\r", enter))
        #expect(committed()! == (9, 15))
    }

    @Test func digitThatCannotStartTwoDigitsAdvances() {
        let (v, committed) = field(8, 30)
        type(v, "945")
        v.keyDown(with: key("\r", enter))
        #expect(committed()! == (9, 45))
        #expect(v.selected == .minute)
    }

    @Test func completedMinutesJumpToTheNextField() {
        let (v, _) = field(8, 30)
        var jumped = 0
        v.onTab = { jumped += 1; return true }
        type(v, "09")
        #expect(v.selected == .minute)
        #expect(jumped == 0)
        type(v, "1")
        #expect(jumped == 0)
        type(v, "5")
        #expect(jumped == 1)
        // A minute digit above 5 completes the segment at once.
        let (w, _) = field(8, 30)
        w.onTab = { jumped += 1; return true }
        type(w, "107")
        #expect(jumped == 2)
        #expect(w.minute == 7)
    }

    @Test func tooLargeSecondDigitStartsOver() {
        let (v, _) = field(8, 30)
        type(v, "27")
        #expect(v.hour == 7)
    }

    @Test func colonJumpsToMinute() {
        let (v, committed) = field(8, 30)
        type(v, "7:5")
        v.keyDown(with: key("\r", enter))
        #expect(committed()! == (7, 5))
    }

    @Test func pastedTimeIsTakenAndCommitted() {
        let (v, committed) = field(8, 30)
        #expect(v.paste(" 9:45\n"))
        #expect(v.paste("1015"))
        #expect(!v.paste("Daily"))
        v.keyDown(with: key("\r", enter))
        #expect(committed()! == (10, 15))
    }

    @Test func optionArrowsStepHourByOneAndMinuteByFive() {
        let (v, _) = field(23, 32)
        v.keyDown(with: key("", up, option: true))
        #expect(v.hour == 0)
        v.keyDown(with: key("", right))
        v.keyDown(with: key("", up, option: true))
        #expect(v.minute == 35)
        v.keyDown(with: key("", down, option: true))
        v.keyDown(with: key("", down, option: true))
        #expect(v.minute == 25)
        v.minute = 0
        v.keyDown(with: key("", down, option: true))
        #expect(v.minute == 55)
    }

    /// Like a line of text: ↑/↓ leave the field, ← on the hour and → on the minute go to the neighbour.
    @Test func arrowsLeaveTheFieldAtItsEdges() {
        let (v, _) = field(8, 30)
        var moves: [FieldCommand] = []
        v.onNavigate = { moves.append($0); return true }
        v.keyDown(with: key("", up))
        v.keyDown(with: key("", down))
        #expect(v.hour == 8 && v.minute == 30)
        v.keyDown(with: key("", left))      // on the hour
        v.keyDown(with: key("", right))     // → minute, stays
        v.keyDown(with: key("", right))     // on the minute
        #expect(moves == [.up, .down, .leftAtStart, .rightAtEnd])
    }

    @Test func tabMovesToMinuteThenLeaves() {
        let (v, _) = field(8, 30)
        var tabbedOut = false
        v.onTab = { tabbedOut = true; return true }
        v.keyDown(with: key("\t", tab))
        #expect(v.selected == .minute)
        v.keyDown(with: key("\t", tab))
        #expect(tabbedOut)
    }

    @Test func escapeRevertsAndIncompleteValueIsDropped() {
        let (v, committed) = field(8, 30)
        type(v, "1")
        v.keyDown(with: key("\u{1b}", escape))
        _ = v.resignFirstResponder()
        #expect(v.hour == 8)
        #expect(committed() == nil)

        let (w, committed2) = field(8, 30)
        w.keyDown(with: key("", backspace))
        _ = w.resignFirstResponder()
        #expect(w.hour == 8)
        #expect(committed2() == nil)
    }

    @Test func unchangedValueIsNotCommitted() {
        let (v, committed) = field(8, 30)
        v.keyDown(with: key("\r", enter))
        #expect(committed() == nil)
    }
}

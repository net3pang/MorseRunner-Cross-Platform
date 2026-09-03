// Port of Main.dfm / TMainForm UI — the main window.
//
// Layout follows the original: contest/station strip on top, band conditions,
// the QSO entry fields with function-key buttons, the score table with the
// summary, and a status bar. The simulation itself runs in SimController.

import AppKit
import MorseRunnerCore

/// Forces text fields to uppercase as the user types (Delphi OnChange
/// behavior for the call/exchange entry fields).
// MARK: - TouchBar Identifiers
extension NSTouchBarItem.Identifier {
    static let runStop   = NSTouchBarItem.Identifier("com.morserunner.runstop")
    static let sendCQ    = NSTouchBarItem.Identifier("com.morserunner.cq")
    static let sendHisNR = NSTouchBarItem.Identifier("com.morserunner.hisnr")
    static let MyCall    = NSTouchBarItem.Identifier("com.morserunner.MyCall")
    static let sendTU    = NSTouchBarItem.Identifier("com.morserunner.tu")
    static let HisCall   = NSTouchBarItem.Identifier("com.morserunner.HisCall")
    static let qm        = NSTouchBarItem.Identifier("com.morserunner.qm")
}

// MARK: - Formatters & Custom Controls

//Force uppercase English letters, numbers, and forward slashes;
//disable Chinese input methods and prevent the Touch Bar from displaying a candidate word bar.
private final class CallInputFormatter: Formatter {
    private let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/ ")

    override func string(for obj: Any?) -> String? {
        return (obj as? String)?.uppercased()
    }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        obj?.pointee = string.uppercased() as NSString
        return true
    }

    override func isPartialStringValid(
        _ partialString: String,
        newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        let upper = partialString.uppercased()
        
        // Filter out illegal characters
        let isAllowed = upper.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
        if !isAllowed { return false }

        // Lowercase characters are automatically converted to uppercase
        if upper != partialString {
            newString?.pointee = upper as NSString
            return false
        }
        return true
    }
}

// Disables the built-in Touch Bar candidate words in the input box
final class NoCandidateTextField: NSTextField {
    override func makeTouchBar() -> NSTouchBar? {
        return nil
    }

    override var touchBar: NSTouchBar? {
        get {
            return window?.touchBar
        }
        set {
        }
    }
}

// MARK: - MainWindowController

@MainActor
public final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let sim = SimController.shared

    // ---- top strip
    private let contestCombo = NSPopUpButton()
    private let callField = NSTextField(string: Settings.call)
    private let exchangeField = NSTextField(string: "")
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let modeCombo = NSPopUpButton()

    // ---- band strip
    private let wpmField = NSTextField(string: "25")
    private let wpmStepper: NSStepper = {
        let s = NSStepper()
        s.minValue = 10
        s.maxValue = 120
        s.increment = 1
        s.integerValue = 25
        return s
    }()
    private let wpmLabel = NSTextField(labelWithString: "wpm")
    private let pitchCombo = NSPopUpButton()
    private let bwCombo = NSPopUpButton()
    private let ritLabel = NSTextField(labelWithString: "RIT 0")

    // ---- Settings menu
    private var serialNRMenuItems: [NSMenuItem] = []

    // ---- conditions
    private let qsbCheck = NSButton(checkboxWithTitle: "QSB", target: nil, action: nil)
    private let qrmCheck = NSButton(checkboxWithTitle: "QRM", target: nil, action: nil)
    private let qrnCheck = NSButton(checkboxWithTitle: "QRN", target: nil, action: nil)
    private let flutterCheck = NSButton(checkboxWithTitle: "Flutter", target: nil, action: nil)
    private let lidsCheck = NSButton(checkboxWithTitle: "Lids", target: nil, action: nil)
    private let monitorSlider = NSSlider(value: 0.75, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let outputVolumeSlider = NSSlider(value: 0.35, minValue: 0, maxValue: 1, target: nil, action: nil)

    // ---- entry
    private let callEntry = NoCandidateTextField(string: "")
    private let exch1Entry = NoCandidateTextField(string: "")
    private let exch2Entry = NoCandidateTextField(string: "")
    private let exch1Label = NSTextField(labelWithString: "RST")
    private let exch2Label = NSTextField(labelWithString: "Exch")

    // ---- score
    private let logTable = NSTableView()
    private let logScroll = NSScrollView()
    private let rawQsoLabel = NSTextField(labelWithString: "")
    private let rawPtsLabel = NSTextField(labelWithString: "")
    private let rawMultLabel = NSTextField(labelWithString: "")
    private let rawScoreLabel = NSTextField(labelWithString: "")
    private let verQsoLabel = NSTextField(labelWithString: "")
    private let verPtsLabel = NSTextField(labelWithString: "")
    private let verMultLabel = NSTextField(labelWithString: "")
    private let verScoreLabel = NSTextField(labelWithString: "")

    // ---- status
    private let clockLabel = NSTextField(labelWithString: "00:00:00")
    private let pileupLabel = NSTextField(labelWithString: "")
    private let rateLabel = NSTextField(labelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "")
    private let hstScoreLabel = NSTextField(labelWithString: "")
    private let statusBar = NSTextField(labelWithString: "")

    private var running = false
    private var monitorSliderWidth: NSLayoutConstraint!
    private var outputSliderWidth: NSLayoutConstraint!
    private var row2View: NSStackView!
    private var keyRowView: NSStackView!

    /// Balance the two volume sliders so they are equal in width and the row
    /// ends on the same vertical line as the F1-F8 key row. Measured at
    /// runtime (NSStackView-to-NSStackView equal-width constraints deadlock).
    private func balanceSliders() {
        let keyWidth = keyRowView.fittingSize.width
        let rowWidth = row2View.fittingSize.width
        let fixedWidth = rowWidth - monitorSliderWidth.constant - outputSliderWidth.constant
        let sliderWidth = max(70, (keyWidth - fixedWidth) / 2)
        monitorSliderWidth.constant = sliderWidth
        outputSliderWidth.constant = sliderWidth
    }

    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 950, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Morse Runner for macOS"
        window.minSize = NSSize(width: 880, height: 560)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        self.init(window: window)
        window.contentViewController = buildContent()
        setup()
        balanceSliders()
    }

    // MARK: - Layout

    private func buildContent() -> NSViewController {
        let vc = NSViewController()
        let root = NSView()

        // ---- row 0: contest / station
        contestCombo.target = self
        contestCombo.action = #selector(contestChanged)
        for def in contestDefinitions {
            contestCombo.addItem(withTitle: def.name)
        }

        callField.placeholderString = "My call"
        callField.target = self
        callField.action = #selector(myCallEntered)
        exchangeField.placeholderString = "Sent exchange (e.g. 3A OR)"
        exchangeField.target = self
        exchangeField.action = #selector(exchangeEntered)

        // persist immediately while typing so the call survives closing the
        // window without Enter/losing focus (original Edit4Change -> dirty)
        NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: callField, queue: .main
        ) { [weak self] _ in
            // observers are posted on the main queue; assume the main actor
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.sim.setMyCall(self.callField.stringValue.uppercased())
                Settings.saveToDefaults()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: exchangeField, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.sim.setMyExchange(self.exchangeField.stringValue.uppercased())
                Settings.saveToDefaults()
            }
        }

        runButton.target = self
        runButton.action = #selector(runToggled)
        modeCombo.addItems(withTitles: ["Pile-Up", "Single Calls", "COMPETITION", "H S T"])
        modeCombo.target = self
        modeCombo.action = #selector(modeChanged)

        callField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        exchangeField.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let row0 = NSStackView(views: [
            label("Contest"), contestCombo,
            label("Call"), callField,
            label("Exch"), exchangeField,
            runButton, modeCombo,
        ])
        row0.orientation = .horizontal
        row0.spacing = 6

        // ---- row 1: band strip
        wpmField.isEditable = true
        wpmField.isSelectable = true
        wpmField.target = self
        wpmField.action = #selector(wpmChanged(_:))
        wpmField.alignment = .center
        wpmField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: wpmField, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if let val = Int(self.wpmField.stringValue) {
                    let clamped = max(10, min(120, val))
                    self.wpmStepper.integerValue = clamped
                    self.sim.setWpm(clamped)
                }
            }
        }
        
        wpmStepper.target = self
        wpmStepper.action = #selector(wpmChanged(_:))
        wpmStepper.autorepeat = true
        pitchCombo.target = self
        pitchCombo.action = #selector(pitchChanged)
        for p in stride(from: 300, through: 1000, by: 50) {
            pitchCombo.addItem(withTitle: "\(p) Hz")
        }
        bwCombo.target = self
        bwCombo.action = #selector(bwChanged)
        for b in stride(from: 100, through: 1000, by: 50) {
            bwCombo.addItem(withTitle: "\(b) Hz")
        }
        // uppercase as-you-type for call / exchange fields

        let inputFormatter = CallInputFormatter()
        for field in [callEntry, exch1Entry, exch2Entry] {
            field.formatter = inputFormatter
            field.isAutomaticTextCompletionEnabled = false
        }

        let row1 = NSStackView(views: [
            label("CW Speed"), wpmField, wpmStepper, wpmLabel,
            label("Pitch"), pitchCombo,
            label("Bandwidth"), bwCombo,
            ritLabel,
        ])
        row1.orientation = .horizontal
        row1.spacing = 6

        // ---- row 2: conditions
        for (check, action) in [(qsbCheck, #selector(conditionChanged)), (qrmCheck, #selector(conditionChanged)),
                                (qrnCheck, #selector(conditionChanged)), (flutterCheck, #selector(conditionChanged)),
                                (lidsCheck, #selector(conditionChanged))] {
            check.target = self
            check.action = action
        }
        monitorSlider.isContinuous = true
        monitorSlider.target = self
        monitorSlider.action = #selector(monitorChanged)
        monitorSliderWidth = monitorSlider.widthAnchor.constraint(equalToConstant: 80)
        monitorSliderWidth.isActive = true
        outputVolumeSlider.isContinuous = true
        outputVolumeSlider.target = self
        outputVolumeSlider.action = #selector(outputVolumeChanged)
        outputSliderWidth = outputVolumeSlider.widthAnchor.constraint(equalToConstant: 80)
        outputSliderWidth.isActive = true
        row2View = NSStackView(views: [
            qsbCheck, qrmCheck, qrnCheck, flutterCheck, lidsCheck,
            label("Self Mon"), monitorSlider,
            label("Output"), outputVolumeSlider,
        ])
        row2View.orientation = .horizontal
        row2View.spacing = 10

        // ---- row 3: QSO entry + function keys
        callEntry.placeholderString = "Call"
        callEntry.target = self
        callEntry.action = #selector(callEntryEntered)
        callEntry.cell?.sendsActionOnEndEditing = false

        // Keep the engine's callsign mirror in sync while the operator types.
        // This is also what enables UpdateCallInMessage to replace trailing
        // letters that have not reached the transmitter yet.
        NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: callEntry, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sim.enteredCall = self.callEntry.stringValue.uppercased()
            }
        }

        exch1Entry.placeholderString = "Exch1"
        exch1Entry.target = self
        exch1Entry.action = #selector(exch1Entered)
        exch1Entry.cell?.sendsActionOnEndEditing = false

        exch2Entry.placeholderString = "Exch2"
        exch2Entry.target = self
        exch2Entry.action = #selector(exch2Entered)
        exch2Entry.cell?.sendsActionOnEndEditing = false

        let fKeys: [(String, StationMessage)] = [
            ("F1 CQ", .cq), ("F2 EXCH", .nr), ("F3 TU", .tu), ("F4 MyCall", .myCall),
            ("F5 HisCall", .hisCall), ("F6 B4", .b4), ("F7 ?", .qm), ("F8 NIL", .nil_),
        ]
        callEntry.widthAnchor.constraint(equalToConstant: 110).isActive = true
        exch1Entry.widthAnchor.constraint(equalToConstant: 70).isActive = true
        exch2Entry.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let entryRow = NSStackView(views: [label("Call"), callEntry,
                                           exch1Label, exch1Entry,
                                           exch2Label, exch2Entry])
        entryRow.orientation = .horizontal
        entryRow.spacing = 4

        let keyRow = NSStackView()
        keyRow.orientation = .horizontal
        keyRow.spacing = 6
        for (title, msg) in fKeys {
            let b = NSButton(title: title, target: self, action: #selector(msgButtonPressed(_:)))
            b.tag = msg.rawValue
            keyRow.addArrangedSubview(b)
        }
        keyRowView = keyRow

        // ---- row 4: score table + summary
        logTable.addTableColumn(makeColumn("UTC", width: 80))
        logTable.addTableColumn(makeColumn("Call", width: 120))
        logTable.addTableColumn(makeColumn("RST/Exch1", width: 90))
        logTable.addTableColumn(makeColumn("Exch2", width: 120))
        logTable.addTableColumn(makeColumn("Corrections", width: 160))
        logTable.addTableColumn(makeColumn("Wpm", width: 60))
        logTable.usesAlternatingRowBackgroundColors = true
        logTable.rowHeight = 17
        logTable.allowsMultipleSelection = false
        logTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        logScroll.documentView = logTable
        logScroll.hasVerticalScroller = true
        // let the table stretch to fill the remaining window width
        logScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        logScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let tableRow = NSStackView(views: [logScroll])
        tableRow.orientation = .horizontal

        // ---- row 5: status (rate / pile-up on the right, same line as clock)
        statusBar.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusBar.lineBreakMode = .byTruncatingTail
        rateLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        pileupLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        hstScoreLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [clockLabel, modeLabel, statusBar,
                                            statusSpacer, rateLabel, pileupLabel, hstScoreLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 12

        // ---- score box: bordered two-column table (Raw | Verified) on the
        // right; fixed width so the window never jumps.
        func sideLabel(_ text: String, bold: Bool = false) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = bold ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12)
            return l
        }
        for l in [rawQsoLabel, rawPtsLabel, rawMultLabel, rawScoreLabel,
                  verQsoLabel, verPtsLabel, verMultLabel, verScoreLabel] {
            l.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        func scoreColumn(_ title: String, _ qso: NSTextField, _ pts: NSTextField,
                         _ mult: NSTextField, _ score: NSTextField) -> NSStackView {
            let v = NSStackView(views: [sideLabel(title, bold: true), qso, pts, mult, score])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 4
            return v
        }
        let scoreInner = NSStackView(views: [
            scoreColumn("Raw", rawQsoLabel, rawPtsLabel, rawMultLabel, rawScoreLabel),
            scoreColumn("Verified", verQsoLabel, verPtsLabel, verMultLabel, verScoreLabel),
        ])
        scoreInner.orientation = .horizontal
        scoreInner.spacing = 24

        let scoreBox = NSBox()
        scoreBox.boxType = .custom
        scoreBox.borderWidth = 1
        scoreBox.cornerRadius = 4
        scoreBox.titlePosition = .noTitle
        scoreBox.contentViewMargins = NSSize(width: 12, height: 10)
        scoreBox.contentView = scoreInner
        scoreBox.translatesAutoresizingMaskIntoConstraints = false
        scoreBox.widthAnchor.constraint(equalToConstant: 250).isActive = true
        scoreBox.setContentHuggingPriority(.required, for: .horizontal)

        // ---- assemble layout: top strip; band/input rows + score box on one line;
        // the QSO log table gets its own full-width row underneath.
        let topArea = NSStackView(views: [row1, row2View, entryRow, keyRow])
        topArea.orientation = .vertical
        topArea.alignment = .leading
        topArea.spacing = 8
        let bodyRow = NSStackView(views: [topArea, scoreBox])
        bodyRow.orientation = .horizontal
        bodyRow.spacing = 16
        bodyRow.alignment = .top

        let stack = NSStackView(views: [row0, bodyRow, tableRow, statusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            logScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            row0.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scoreBox.topAnchor.constraint(equalTo: bodyRow.topAnchor),
            tableRow.trailingAnchor.constraint(equalTo: scoreBox.trailingAnchor),
        ])
        vc.view = root
        return vc
    }

    private func makeColumn(_ title: String, width: CGFloat) -> NSTableColumn {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
        col.title = title
        col.width = width
        return col
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    // MARK: - Setup

    private func setup() {
        Settings.loadFromDefaults()
        logTable.dataSource = self
        logTable.delegate = self
        SimEngine.shared.uiHooks.userName = Settings.hamName
        SimEngine.shared.uiHooks.volume = Float(monitorSlider.doubleValue)

        // engine -> UI hooks
        SimEngine.shared.uiHooks.onScoreTableInsert = { [weak self] row in
            self?.logRows.append(row)
            self?.logTable.reloadData()
            if let n = self?.logRows.count, n > 0 {
                self?.logTable.scrollRowToVisible(n - 1)
            }
        }
        SimEngine.shared.uiHooks.onScoreTableUpdate = { [weak self] index, row in
            guard let self, self.logRows.indices.contains(index) else { return }
            self.logRows[index] = row
            self.logTable.reloadData(forRowIndexes: IndexSet(integer: index),
                                     columnIndexes: IndexSet(integersIn: 0..<self.logTable.tableColumns.count))
        }
        SimEngine.shared.uiHooks.onStatsUpdate = { [weak self] s in
            self?.rawQsoLabel.stringValue = "qso: \(s.qsoCount)"
            self?.rawPtsLabel.stringValue = "Pts: \(s.points)"
            self?.rawMultLabel.stringValue = "Mult: \(s.mults)"
            self?.rawScoreLabel.stringValue = "Score: \(s.points * s.mults)"
            self?.verQsoLabel.stringValue = "qso: \(s.verifiedQsoCount)"
            self?.verPtsLabel.stringValue = "Pts: \(s.verifiedPoints)"
            self?.verMultLabel.stringValue = "Mult: \(s.verifiedMults)"
            self?.verScoreLabel.stringValue = "Score: \(s.verifiedPoints * s.verifiedMults)"
        }
        SimEngine.shared.uiHooks.onRateUpdate = { [weak self] rate in
            self?.rateLabel.stringValue = "\(rate) qso/hr"
        }
        SimEngine.shared.uiHooks.onClockUpdate = { [weak self] t in
            self?.clockLabel.stringValue = t
        }
        SimEngine.shared.uiHooks.onPileupCount = { [weak self] n in
            self?.pileupLabel.stringValue = "\(n)"
        }
        SimEngine.shared.uiHooks.onStatusBar = { [weak self] text, isError in
            self?.statusBar.stringValue = text
            self?.statusBar.textColor = isError ? .systemRed : .labelColor
        }
        SimEngine.shared.uiHooks.onExchangeLabel = { [weak self] text in
            self?.exch2Label.stringValue = text
        }
        SimEngine.shared.uiHooks.onRecvExchTypes = { [weak self] types in
            guard let self else { return }
            self.exch1Label.stringValue = exchange1Settings[types.exch1]?.caption ?? "Exch1"
            self.exch2Label.stringValue = exchange2Settings[types.exch2]?.caption ?? "Exch2"
            self.exch1Entry.placeholderString = exchange1Settings[types.exch1]?.caption ?? "Exch1"
            self.exch2Entry.placeholderString = exchange2Settings[types.exch2]?.caption ?? "Exch2"
        }
        SimEngine.shared.uiHooks.onWipeBoxes = { [weak self] in
            self?.callEntry.stringValue = ""
            self?.exch1Entry.stringValue = ""
            self?.exch2Entry.stringValue = ""
            self?.window?.makeFirstResponder(self?.callEntry)
        }
        SimEngine.shared.uiHooks.onAdvance = { [weak self] in
            guard let self else { return }
            // original Advance(): auto-fill 599 when the received Exch1 is RST
            let types = SimEngine.shared.uiHooks.recvExchTypes
            if types.exch1 == .rst && Settings.runMode != .hst && self.exch1Entry.stringValue.isEmpty {
                self.exch1Entry.stringValue = "599"
                self.sim.enteredExch1 = "599"
            }
            self.window?.makeFirstResponder(self.exch2Entry)
        }
        SimEngine.shared.uiHooks.onRunState = { [weak self] mode in
            guard let self else { return }
            self.running = mode != .stop
            self.runButton.title = mode == .stop ? "Run" : "Stop"
            let names = ["", "Pile-Up", "Single Calls", "COMPETITION", "H S T"]
            self.modeLabel.stringValue = mode == .stop ? "" : names[mode.rawValue]
            self.modeLabel.textColor = (mode == .wpx || mode == .hst) ? .systemRed : .systemGreen
            
            // Refresh Touch Bar
            self.touchBar = nil
            
            if mode != .stop {
                // fresh run: clear the score table
                self.logRows = []
                self.logTable.reloadData()
            }
        }
        SimEngine.shared.uiHooks.onHstScore = { [weak self] score in
            self?.hstScoreLabel.stringValue = "HST Score: \(score)"
        }
        SimEngine.shared.uiHooks.onUserNameChange = { [weak self] _ in
            self?.window?.title = "Morse Runner for macOS"
        }
        SimEngine.shared.uiHooks.onShowScore = { [weak self] in
            self?.showScoreDialog()
        }

        // the engine requests a stop (run expired / FStopPressed)
        SimEngine.shared.uiHooks.onRunStopped = { [weak self] in
            self?.sim.handleRunStopped()
        }

        // debug CW stream to the status bar — only when the debug option is
        // enabled (original: "if BDebugCwDecoder and not (self is TQrmStation)").
        SimEngine.shared.debugCwStream = { [weak self] text in
            guard Settings.debugCwDecoder else { return }
            Log.shared.sbarUpdateDebugMsg(text)
        }
        SimEngine.shared.debugGhosting = { [weak self] text in
            self?.statusBar.stringValue = (text + "; " + (self?.statusBar.stringValue ?? "")).prefix(80).description
        }

        // initial contest + widgets
        sim.setContest(Settings.simContest)
        contestCombo.selectItem(at: Settings.simContest.rawValue)
        callField.stringValue = Settings.call
        exchangeField.stringValue = sim.exchangeEdit
        wpmField.stringValue = String(Settings.wpm)
        wpmStepper.integerValue = Settings.wpm
        wpmChanged(nil)
        pitchCombo.selectItem(at: (Settings.pitch - 300) / 50)
        bwCombo.selectItem(at: (Settings.bandWidth - 100) / 50)
        buildSettingsMenu()
        qsbCheck.state = Settings.qsb ? .on : .off
        qrmCheck.state = Settings.qrm ? .on : .off
        qrnCheck.state = Settings.qrn ? .on : .off
        flutterCheck.state = Settings.flutter ? .on : .off
        lidsCheck.state = Settings.lids ? .on : .off
        SimEngine.shared.uiHooks.volume = 0.75
        monitorSlider.doubleValue = 0.75
        sim.masterVolume = 0.35
        outputVolumeSlider.doubleValue = 0.35
        updateRitLabel()
        updateColumns(for: Settings.simContest)
        installKeyMonitor()
    }

    /// Copy the entry fields into the controller before sending a message,
    /// so HisCall uses the call currently being typed (not the previous QSO).
    private func syncEntryFields() {
        sim.enteredCall = callEntry.stringValue.uppercased()
        sim.enteredExch1 = exch1Entry.stringValue.uppercased()
        sim.enteredExch2 = exch2Entry.stringValue.uppercased()
    }

    /// Global key handling (port of FormKeyDown/FormKeyPress): function keys
    /// F1-F11, Insert, Esc, and the '.' ';' ',' '[' '+' shortcuts.
    private func installKeyMonitor() {
        // F-key keyCodes on macOS: F1=122, F2=120, F3=99, F4=118, F5=96,
        // F6=97, F7=98, F8=100, F9=101, F10=109, F11=103
        let f1toF8: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100]
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let chars = event.charactersIgnoringModifiers ?? ""
            let mods = event.modifierFlags
            let keyCode = event.keyCode

            // function keys (sync typed call/exchange first)
            if let idx = f1toF8.firstIndex(of: keyCode) {
                self.syncEntryFields()
                let msgs: [StationMessage] = [.cq, .nr, .tu, .myCall, .hisCall, .b4, .qm, .nil_]
                self.sim.sendMsg(msgs[idx])
                return nil
            }
            switch keyCode {
            case 48:  // Tab: while running, cycle only Call/Exch1/Exch2
                if self.running {
                    self.cycleEntryFields()
                    return nil
                }
                return event
            case 101:  // F9
                if mods.contains(.control) || mods.contains(.option) {
                    self.changeSpeed(-1)
                    return nil
                }
                return event
            case 109:  // F10
                if mods.contains(.control) || mods.contains(.option) {
                    self.changeSpeed(1)
                    return nil
                }
                return event
            case 103:  // F11
                self.sim.wipeBoxes()
                return nil
            default:
                break
            }

            if keyCode == 53 {  // Esc: abort send
                self.sim.abortSend()
                return nil
            }
            if let special = event.specialKey {
                switch special {
                case .insert:
                    self.sim.hisAndNR()
                    return nil
                case .pageUp:
                    self.changeSpeed(1)
                    return nil
                case .pageDown:
                    self.changeSpeed(-1)
                    return nil
                case .upArrow:
                    self.adjustRit(1)
                    return nil
                case .downArrow:
                    self.adjustRit(-1)
                    return nil
                default:
                    return event
                }
            }
     
            // character shortcuts
            if mods.contains(.control) && chars.lowercased() == "w" {
                self.sim.wipeBoxes()
                return nil
            }
            switch chars {
            case ";":
                self.syncEntryFields()
                self.sim.hisAndNR()
                return nil
            case ".", "+", "[", ",":
                self.syncEntryFields()
                self.sim.tuAndSave()
                return nil
            case " ":
                // advance to the next exchange field
                if let currentEditor = self.window?.firstResponder as? NSTextView {
                    if currentEditor.delegate as? NSTextField === self.callEntry {
                        // Call -> Exch2
                        self.window?.makeFirstResponder(self.exch2Entry)
                        if let editor = self.exch2Entry.currentEditor() {
                            let len = self.exch2Entry.stringValue.count
                            editor.selectedRange = NSRange(location: len, length: 0)
                        }
                        return nil
                    } else if currentEditor.delegate as? NSTextField === self.exch2Entry {
                        // Exch2 -> Call
                        self.window?.makeFirstResponder(self.callEntry)
                        if let editor = self.callEntry.currentEditor() {
                            let len = self.callEntry.stringValue.count
                            editor.selectedRange = NSRange(location: len, length: 0)
                        }
                        return nil
                    }
                }
            default:
                break
            }
            return event
        }
    }

    private func cycleEntryFields() {
        // While running, Tab moves Call -> Exch1 -> Exch2 -> Call, with the
        // caret at the end of the text (no select-all).
        let current = (window?.firstResponder as? NSTextView)?.delegate as? NSTextField
        let next: NSTextField
        if current === callEntry {
            next = exch1Entry
        } else if current === exch1Entry {
            next = exch2Entry
        } else {
            next = callEntry
        }
        window?.makeFirstResponder(next)
        if let editor = next.currentEditor() {
            editor.selectedRange = NSRange(location: next.stringValue.count, length: 0)
        }
    }

    private func changeSpeed(_ delta: Int) {
        let wpm = max(10, min(120, Settings.wpm + delta * Settings.wpmStepRate))
        wpmStepper.integerValue = wpm
        wpmChanged(nil)
    }

    private func adjustRit(_ delta: Int) {
        Settings.rit = max(-500, min(500, Settings.rit + delta * Settings.ritStepIncr))
        sim.setRit(Settings.rit)
        updateRitLabel()
    }

    /// Per-contest score-table columns (port of Log.ScoreTableInit).
    private func updateColumns(for contest: SimContest) {
        let headers: [String]
        switch contest {
        case .cwt: headers = ["UTC", "Call", "Name", "Exch", "Corrections", "Wpm"]
        case .sst: headers = ["UTC", "Call", "Name", "Exch", "Corrections", "Wpm"]
        case .fieldDay: headers = ["UTC", "Call", "Class", "Sect", "Corrections", "Wpm"]
        case .arrlSS: headers = ["UTC", "Call", "Nr", "Pr", "Chk", "Sect", "Corrections", "Wpm"]
        case .naQp: headers = ["UTC", "Call", "Name", "State", "Pref", "Corrections", "Wpm"]
        case .cqww: headers = ["UTC", "Call", "RST", "Zone", "Corrections", "Wpm"]
        case .arrlDx, .allJa, .acag, .iaruHf: headers = ["UTC", "Call", "RST", "Exch", "Corrections", "Wpm"]
        case .wpx: headers = ["UTC", "Call", "RST", "Exch", "Corrections", "Wpm"]
        case .hst: headers = ["UTC", "Call", "RST", "Exch", "Score", "Correct", "Wpm"]
        }
        while logTable.tableColumns.count < headers.count {
            logTable.addTableColumn(makeColumn("", width: 70))
        }
        while logTable.tableColumns.count > headers.count {
            logTable.removeTableColumn(logTable.tableColumns.last!)
        }
        for (i, h) in headers.enumerated() {
            logTable.tableColumns[i].title = h
            logTable.tableColumns[i].width = h == "Corrections" ? 110 : 65
        }
        logRows = []
        logTable.reloadData()
    }

    // MARK: - Actions

    @objc private func contestChanged() {
        let idx = contestCombo.indexOfSelectedItem
        if let contest = SimContest(rawValue: idx) {
            sim.setContest(contest)
            exchangeField.stringValue = sim.exchangeEdit
            updateColumns(for: contest)
            updateSerialNRMenuEnabled()
            Settings.saveToDefaults()
        }
    }

    // save regardless of SetMyCall's exchange-validation result, exactly
    // like the original Edit4Exit (SetMyCall without checking the return)
    @objc private func myCallEntered() {
        _ = sim.setMyCall(callField.stringValue.uppercased())
        Settings.saveToDefaults()
    }

    @objc private func exchangeEntered() {
        _ = sim.setMyExchange(exchangeField.stringValue.uppercased())
        Settings.saveToDefaults()
    }

    @objc private func runToggled() {
        if running {
            sim.stop()
        } else {
            let mode = RunMode(rawValue: modeCombo.indexOfSelectedItem + 1) ?? .pileup
            sim.run(mode)
        }
    }

    // modes are enabled only while stopped
    @objc private func modeChanged() {
        guard !running else { return }
        let mode = RunMode(rawValue: modeCombo.indexOfSelectedItem + 1) ?? .pileup
        if mode == .wpx || mode == .hst {
            Settings.compDuration = Settings.duration
        }
    }

    @objc private func wpmChanged(_ sender: Any?) {
        // The stepper drives the value when clicked (or when called
        // programmatically after setting the stepper); the text field drives
        // it when the user types and presses Return. Without this, a stepper
        // click is immediately overwritten by the field's old text.
        let sourceValue: Int
        if let senderField = sender as? NSTextField, senderField === wpmField {
            sourceValue = Int(wpmField.stringValue) ?? wpmStepper.integerValue
        } else {
            sourceValue = wpmStepper.integerValue
        }
        let wpm = max(10, min(120, sourceValue))
        wpmField.stringValue = String(wpm)
        wpmStepper.integerValue = wpm
        wpmLabel.stringValue = "\(wpm) wpm"
        sim.setWpm(wpm)
    }

    @objc private func pitchChanged() {
        sim.setPitch(300 + pitchCombo.indexOfSelectedItem * 50)
    }

    @objc private func bwChanged() {
        sim.setBandwidth(100 + bwCombo.indexOfSelectedItem * 50)
    }

    @objc private func conditionChanged() {
        Settings.qsb = qsbCheck.state == .on
        Settings.qrm = qrmCheck.state == .on
        Settings.qrn = qrnCheck.state == .on
        Settings.flutter = flutterCheck.state == .on
        Settings.lids = lidsCheck.state == .on
    }

    // persist dB: Db = 60 * (value - 1)
    @objc private func monitorChanged() {
        SimEngine.shared.uiHooks.volume = Float(monitorSlider.doubleValue)
        Settings.monLevel = Int((monitorSlider.doubleValue - 1) * 60)
    }

    @objc private func outputVolumeChanged() {
        sim.masterVolume = Float(outputVolumeSlider.doubleValue)
    }

    /// Settings -> Serial NR (Start/Mid/End of Contest, Custom range).
    @objc private func serialNRMenuItemSelected(_ sender: NSMenuItem) {
        guard let mode = SerialNRType(rawValue: sender.tag) else { return }
        if mode == .customRange {
            let current = Settings.serialNRSettings[.customRange]?.rangeStr ?? "01-99"
            guard let newRange = promptForCustomRange(current: current) else { return }
            if let parsed = Settings.serialNRSettings[.customRange],
               let s = parseRange(newRange, into: parsed) {
                Settings.serialNRSettings[.customRange] = s
            } else {
                return
            }
        }
        Settings.serialNR = mode
        Contest.shared?.serialNrModeChanged()
        updateMenuCheckmarks(sender.menu, selectedTag: sender.tag)
        Settings.saveToDefaults()
    }

    // accept "01-99" or "1-99"
    private func parseRange(_ text: String, into s: SerialNumberSettings) -> SerialNumberSettings? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[0] <= parts[1] else { return nil }
        var copy = s
        copy.rangeStr = text.uppercased()
        copy.minVal = parts[0]
        copy.maxVal = parts[1]
        copy.minDigits = max(1, String(parts[0]).count)
        copy.maxDigits = max(1, String(parts[1]).count)
        return copy
    }

    private func promptForCustomRange(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Custom Serial NR Range"
        alert.informativeText = "Enter a range, e.g. 01-99"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    /// Settings -> Duration (original menu 5/10/15/30/60 min).
    @objc private func durationMenuItemSelected(_ sender: NSMenuItem) {
        Settings.duration = max(1, min(180, sender.tag))
        updateMenuCheckmarks(sender.menu, selectedTag: sender.tag)
        Settings.saveToDefaults()
    }

    /// Settings -> CW Max/Min Rx Speed (original menu options 0,1,2,4,6,8,10).
    @objc private func rxSpeedMenuItemSelected(_ sender: NSMenuItem) {
        if sender.menu?.title == "CW Max Rx Speed" {
            Settings.maxRxWpm = sender.tag
        } else {
            Settings.minRxWpm = sender.tag
        }
        updateMenuCheckmarks(sender.menu, selectedTag: sender.tag)
        Settings.saveToDefaults()
    }

    
    /// Settings -> Activity (1..9).
    @objc private func activityMenuItemSelected(_ sender: NSMenuItem) {
        Settings.activity = max(1, min(9, sender.tag))
        updateMenuCheckmarks(sender.menu, selectedTag: sender.tag)
        Settings.saveToDefaults()
    }

    @objc private func callEntryEntered(_ sender: Any) {
        // Press Enter to disable the selection of all content in the input box.
        sim.enteredCall = callEntry.stringValue.uppercased()
        sim.enterKeyPressed()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let editor = self.callEntry.currentEditor() else { return }
            
            // Set the selection length to 0 (i.e., disable highlighting), and place it at the end of the text.
            let endLocation = self.callEntry.stringValue.count
            editor.selectedRange = NSRange(location: endLocation, length: 0)
        }
    }

    @objc private func exch1Entered() {
        sim.enteredCall = callEntry.stringValue.uppercased()
        sim.enteredExch1 = exch1Entry.stringValue.uppercased()
        sim.enterKeyPressed()
    }

    @objc private func exch2Entered() {
        sim.enteredCall = callEntry.stringValue.uppercased()
        sim.enteredExch1 = exch1Entry.stringValue.uppercased()
        sim.enteredExch2 = exch2Entry.stringValue.uppercased()
        sim.enterKeyPressed()
    }

    @objc private func msgButtonPressed(_ sender: NSButton) {
        syncEntryFields()
        if let msg = StationMessage(rawValue: sender.tag) {
            sim.sendMsg(msg)
        }
    }

    @objc private func conditionCheckChanged() {
        conditionChanged()
    }

    /// Build the Settings menu (Activity/Duration/CW Rx speeds/Serial NR),
    /// mirroring the original menu-driven layout and keeping the main window
    /// clean. Serial NR is only enabled for contests that use serial numbers.
    private func buildSettingsMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "Settings")
        settingsItem.submenu = settingsMenu

        func addChoices(_ title: String, values: [Int], action: Selector, selected: Int) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            for v in values {
                let mi = NSMenuItem(title: "\(v)", action: action, keyEquivalent: "")
                mi.tag = v
                mi.target = self
                mi.state = v == selected ? .on : .off
                sub.addItem(mi)
            }
            item.submenu = sub
            settingsMenu.addItem(item)
        }

        addChoices("Activity", values: Array(1...9),
                   action: #selector(activityMenuItemSelected(_:)), selected: Settings.activity)
        addChoices("Duration (min)", values: [5, 10, 15, 30, 60],
                   action: #selector(durationMenuItemSelected(_:)), selected: Settings.duration)
        addChoices("CW Max Rx Speed", values: [0, 1, 2, 4, 6, 8, 10],
                   action: #selector(rxSpeedMenuItemSelected(_:)), selected: Settings.maxRxWpm)
        addChoices("CW Min Rx Speed", values: [0, 1, 2, 4, 6, 8, 10],
                   action: #selector(rxSpeedMenuItemSelected(_:)), selected: Settings.minRxWpm)

        // Serial NR
        let serialItem = NSMenuItem(title: "Serial NR", action: nil, keyEquivalent: "")
        let serialMenu = NSMenu(title: "Serial NR")
        let serialTitles = ["Start of Contest", "Mid-Contest", "End of Contest", "Custom Range..."]
        for (i, title) in serialTitles.enumerated() {
            let mi = NSMenuItem(title: title, action: #selector(serialNRMenuItemSelected(_:)), keyEquivalent: "")
            mi.tag = i
            mi.target = self
            mi.state = i == Settings.serialNR.rawValue ? .on : .off
            serialMenu.addItem(mi)
            serialNRMenuItems.append(mi)
        }
        serialItem.submenu = serialMenu
        settingsMenu.addItem(serialItem)

        // insert Settings before the Window menu (last item)
        mainMenu.insertItem(settingsItem, at: max(1, mainMenu.items.count - 1))
        updateSerialNRMenuEnabled()
    }

    private func updateMenuCheckmarks(_ menu: NSMenu?, selectedTag: Int) {
        for item in menu?.items ?? [] {
            item.state = item.tag == selectedTag ? .on : .off
        }
    }

    /// Serial NR only applies to contests whose Exch2 is a serial number
    /// (CQ WPX, HST). For CQ WW (CQ zone) etc. the menu is disabled.
    private func updateSerialNRMenuEnabled() {
        let enabled = Settings.activeContest.exchType2 == .serialNr
        for item in serialNRMenuItems {
            item.isEnabled = enabled
            item.state = item.tag == Settings.serialNR.rawValue ? .on : .off
        }
    }

    private func updateRitLabel() {
        ritLabel.stringValue = "RIT \(Settings.rit)"
    }

    // MARK: - NSTableViewDataSource & Delegate

    private var logRows: [ScoreTableRow] = []

    public func numberOfRows(in tableView: NSTableView) -> Int {
        logRows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < logRows.count else { return nil }
        let cols = logRows[row].columns
        let idx = tableView.tableColumns.firstIndex { $0 === tableColumn } ?? 0
        guard idx < cols.count else { return nil }
        let cell = NSTextField(labelWithString: cols[idx])
        cell.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return cell
    }
    
    /// End-of-run score dialog (port of PopupScoreWpx / PopupScoreHst).
    private func showScoreDialog() {
        let log = Log.shared
        let verifiedScore = log.verifiedPoints * log.verifiedMultList.count
        let rawScore = log.rawPoints * log.rawMultList.count
        let mode = Settings.runMode == .hst ? "HST" : "Competition"
        let message: String
        if Settings.runMode == .hst {
            message = "HST Score: \(log.rawPoints)\nVerified: \(log.verifiedPoints)"
        } else {
            message = """
            \(mode) complete.

            Raw:      \(log.rawPoints) pts × \(log.rawMultList.count) mults = \(rawScore)
            Verified: \(log.verifiedPoints) pts × \(log.verifiedMultList.count) mults = \(verifiedScore)
            """
        }
        let alert = NSAlert()
        alert.messageText = "Morse Runner — \(mode) Results"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - NSTouchBarDelegate

extension MainWindowController: NSTouchBarDelegate {

    public override func makeTouchBar() -> NSTouchBar? {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [
            .runStop, .sendCQ, .sendHisNR, .sendTU, .MyCall, .HisCall, .qm
        ]
        return touchBar
    }

    public func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)

        switch identifier {
        case .runStop:
            let btn = NSButton(title: running ? "STOP" : "RUN", target: self, action: #selector(touchBarRunToggled))
            btn.bezelColor = running ? .systemRed : .systemGreen
            item.view = btn

        case .sendCQ:
            item.view = NSButton(title: "CQ (F1)", target: self, action: #selector(touchBarSendCQ))

        case .sendHisNR:
            item.view = NSButton(title: "Exch (F2)", target: self, action: #selector(touchBarSendNR))

        case .sendTU:
            item.view = NSButton(title: "TU (F3)", target: self, action: #selector(touchBarSendTU))
            
        case .MyCall:
            item.view = NSButton(title: "MyCall (F4)", target: self, action: #selector(touchBarSendMyCall))

        case .HisCall:
            item.view = NSButton(title: "HisCall (F5)", target: self, action: #selector(touchBarSendHisCall))
            
        case .qm:
            item.view = NSButton(title: "? (F7)", target: self, action: #selector(touchBarSendqm))

        default:
            return nil
        }
        return item
    }

    @objc private func touchBarRunToggled() {
        runToggled()
    }

    @objc private func touchBarSendCQ() {
        syncEntryFields()
        sim.sendMsg(.cq)
    }

    @objc private func touchBarSendNR() {
        syncEntryFields()
        sim.sendMsg(.nr)
    }

    @objc private func touchBarSendMyCall() {
        syncEntryFields()
        sim.sendMsg(.myCall)
    }

    @objc private func touchBarSendTU() {
        syncEntryFields()
        sim.sendMsg(.tu)
    }

    @objc private func touchBarSendHisCall() {
        syncEntryFields()
        sim.sendMsg(.hisCall)
    }
        
    @objc private func touchBarSendqm() {
        syncEntryFields()
        sim.sendMsg(.qm)
    }
}

// Prevent input prediction from occupying the Touch Bar
final class NoCandidateTextView: NSTextView {
    override func makeTouchBar() -> NSTouchBar? {
        return nil
    }

    override var touchBar: NSTouchBar? {
        get { return window?.touchBar }
        set { }
    }
}

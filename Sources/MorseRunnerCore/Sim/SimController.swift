// Port of TMainForm's engine-facing behavior (Main.pas): contest switching,
// run/stop, message sending, and the Enter-key QSO flow. The UI layer calls
// into this controller; the controller reports back through SimEngine hooks.

import Foundation

public final class SimController: @unchecked Sendable {
    public nonisolated(unsafe) static let shared = SimController()

    // ---- input state (owned by the UI via hooks, mirrored here)
    /// My callsign field (MainForm.Edit4).
    private(set) var myCall = Settings.call
    /// Sent exchange field (MainForm.ExchangeEdit).
    public private(set) var exchangeEdit = ""
    /// Entry fields (MainForm.Edit1/2/3).
    public var enteredCall = "" {
        didSet {
            SimEngine.shared.uiHooks.enteredCall = enteredCall

            // The original runner lets the operator correct a callsign while
            // it is being keyed.  MyStation compares the already transmitted
            // samples and replaces only the not-yet-sent suffix (or updates a
            // later queued <his> token).  Calling this on every edit keeps the
            // UI responsive without changing the Enter/QSO state machine.
            Contest.shared?.me.updateCallInMessage(enteredCall)
        }
    }
    public var enteredExch1 = "" { didSet { SimEngine.shared.uiHooks.enteredExch1 = enteredExch1 } }
    public var enteredExch2 = "" { didSet { SimEngine.shared.uiHooks.enteredExch2 = enteredExch2 } }

    /// Received exchange types for the current entry (MainForm.RecvExchTypes).
    public private(set) var recvExchTypes = ExchTypes.undef {
        didSet { SimEngine.shared.uiHooks.recvExchTypes = recvExchTypes }
    }

    /// Audio sink. The macOS app injects its AVAudioEngine backend; the
    /// default silent backend keeps headless/terminal runs working anywhere.
    public var audioBackend: AudioBackend = SilentAudioBackend()

    /// Master output volume 0..1 (applies to the player node). The original
    /// had no master volume — only the self-monitor level — which made the
    /// fixed AGC ceiling (20k of 32k full scale) very loud on speakers.
    public var masterVolume: Float = 0.35 {
        didSet { audioBackend.playerVolume = masterVolume }
    }

    /// Port of MainForm.RunMode.
    var runMode: RunMode {
        get { Settings.runMode }
        set { Settings.runMode = newValue }
    }

    private init() {}

    // MARK: - contest switching

    /// Port of TMainForm.SetContest.
    public func setContest(_ contestNum: SimContest) {
        wipeBoxes()

        Settings.simContest = contestNum
        Contest.shared = nil  // drop prior contest

        // create the new contest
        let contest = ContestFactory.create(contestNum)
        Contest.shared = contest

        // load the original or Farnsworth keyer
        if contestNum == .sst {
            Keyer.shared = FarnsKeyer()
        } else {
            Keyer.shared = Keyer()
        }

        // initialize contest-specific data
        if Settings.userExchangeTbl[contestNum.rawValue].isEmpty {
            Settings.userExchangeTbl[contestNum.rawValue] = Settings.activeContest.exchDefault
        }
        exchangeEdit = Settings.userExchangeTbl[contestNum.rawValue].uppercased()

        // use the loaded Settings.call (may have been read from defaults after
        // this controller was created), not the stale initial value
        setMyCall(Settings.call.uppercased())
        setMyExchange(exchangeEdit)
        SimEngine.shared.uiHooks.onExchangeLabel?(
            exchange2Settings[Settings.activeContest.exchType2]?.caption ?? "Exch")
    }

    /// Port of TMainForm.SetMyCall.
    @discardableResult
    public func setMyCall(_ call: String) -> Bool {
        myCall = call
        Settings.call = call
        guard let contest = Contest.shared else { return false }
        contest.me.myCall = call
        // some contests have contest-specific settings (e.g. location local/dx);
        // sets Me.SentExchTypes
        guard contest.onSetMyCall(call) else { return false }

        // update my "sent" exchange; may report an error in the status bar
        let result = setMyExchange(exchangeEdit.trimmingCharacters(in: .whitespaces))
        SimEngine.shared.uiHooks.onUserNameChange?(Settings.hamName)
        return result
    }

    /// Port of TMainForm.SetMyExchange.
    @discardableResult
    public func setMyExchange(_ exchange: String) -> Bool {
        guard let contest = Contest.shared else { return false }
        var tokens: [String] = []
        if let err = contest.validateMyExchange(exchange, tokens: &tokens) {
            SimEngine.shared.uiHooks.onStatusBar?(err, true)
            exchangeEdit = exchange
            Settings.userExchangeTbl[Settings.simContest.rawValue] = exchange
            return false
        }
        SimEngine.shared.uiHooks.onStatusBar?("", false)

        // set contest-specific sent exchange values
        setMyExch1(tokens[safe: 0] ?? "")
        setMyExch2(tokens[safe: 1] ?? "")

        exchangeEdit = exchange
        Settings.userExchangeTbl[Settings.simContest.rawValue] = exchange
        return true
    }

    private func setMyExch1(_ value: String) {
        guard let contest = Contest.shared else { return }
        switch contest.me.sentExchTypes.exch1 {
        case .rst:
            // Original SetMyExch1(etRST): expand cut numbers (E->5, N->9)
            // into Me.RST and also store the literal into Me.Exch1, so
            // contests like CQ WW send "5NN 3" instead of the stale "3A OR".
            let s = value.uppercased()
                .replacingOccurrences(of: "E", with: "5")
                .replacingOccurrences(of: "N", with: "9")
            contest.me.rst = Int(s) ?? 0
            contest.me.exch1 = value
        case .opName: contest.me.opName = value
        case .fdClass: contest.me.exch1 = value
        case .ssNrPrecedence:
            // SS: '<nr> <prec>' or '# <prec>' or '<prec>'
            let parts = value.split(separator: " ")
            if let first = parts.first, let nr = Int(first) {
                contest.me.nr = nr
            }
            if let prec = parts.last {
                contest.me.prec = String(prec)
            }
            contest.me.exch1 = value
        case .undef: break
        }
    }

    private func setMyExch2(_ value: String) {
        guard let contest = Contest.shared else { return }
        switch contest.me.sentExchTypes.exch2 {
        case .serialNr:
            // Original SetMyExch2(etSerialNr): expand cut numbers, then
            //   HST            -> 1
            //   '#' + Mid/End  -> random decade
            //   numeric        -> that value
            //   otherwise      -> 1   ('#' + Start of Contest starts at 001)
            let s = value.uppercased()
                .replacingOccurrences(of: "T", with: "0")
                .replacingOccurrences(of: "O", with: "0")
                .replacingOccurrences(of: "N", with: "9")
            if Settings.simContest == .hst {
                contest.me.nr = 1
            } else if s.contains("#") && [SerialNRType.midContest, .endContest].contains(Settings.serialNR) {
                contest.me.nr = 1 + (contest.getRandomSerialNR() / 10) * 10
            } else if let v = Int(s) {
                contest.me.nr = v
            } else {
                contest.me.nr = 1
            }
        case .genericField, .arrlSection, .stateProv, .cqZone, .ituZone,
             .power, .jaPref, .jaCity, .naQpExch2, .naQpNonNaExch2:
            contest.me.exch2 = value
        case .ssCheckSection:
            // SS: '<check> <section>'
            let parts = value.split(separator: " ")
            if let first = parts.first {
                contest.me.chk = Int(first) ?? 0
            }
            if let sect = parts.last {
                contest.me.sect = String(sect)
            }
            contest.me.exch2 = value
        case .age, .undef: break
        }
    }

    // MARK: - settings

    public func setWpm(_ wpm: Int) {
        Settings.wpm = max(10, min(120, wpm))
        Contest.shared?.me.setWpm(Settings.wpm)
    }

    public func setPitch(_ pitch: Int) {
        Settings.pitch = pitch
        Contest.shared?.me.pitch = pitch
    }

    public func setBandwidth(_ bw: Int) {
        Settings.bandWidth = bw
        if let filt = Contest.shared?.filt {
            filt.points = bankersRound(0.7 * Float(AudioConstants.defaultRate) / Float(Settings.bandWidth))
            filt.gainDb = 10 * log10(500 / Float(Settings.bandWidth))
        }
    }

    public func setQsk(_ qsk: Bool) {
        Settings.qsk = qsk
    }

    public func setRit(_ rit: Int) {
        Settings.rit = rit
    }

    // MARK: - run / stop

    /// Port of TMainForm.Run(Value).
    public func run(_ value: RunMode) {
        guard value != runMode else { return }
        guard let contest = Contest.shared else { return }

        if value != .stop {
            // HST requires the HST contest and start-of-contest serial mode
            if value == .hst && (Settings.simContest != .hst || Settings.serialNR != .startContest) {
                SimEngine.shared.uiHooks.onStatusBar?(
                    "Error: HST requires 'HST (High Speed Test)' contest and 'Start of Contest' serial NR.",
                    true)
                return
            }
            // load call history and other contest-specific setup
            if !contest.onContestPrepareToStart(Settings.call, sentExchange: exchangeEdit) {
                return
            }
        }

        let isStop = value == .stop
        runMode = value

        if isStop {
            audioBackend.stop()
            // must notify the UI so the Run button returns to "Run"
            SimEngine.shared.uiHooks.onRunState?(.stop)
        } else {
            contest.me.abortSend()
            contest.blockNumber = 0
            SimEngine.shared.stopHandled = false
            SimEngine.shared.runExpired = false
            Log.shared.clear()
            wipeBoxes()
            contest.initContest()
            // initContest reset Me (sentExchTypes -> undef); restore the sent
            // exchange types and re-apply the exchange so validation passes
            // and cut-number formatting works (original Run never re-inits Me).
            _ = contest.onSetMyCall(Settings.call)
            _ = setMyExchange(exchangeEdit)
            Log.shared.updateStats(verifyResults: false)
            // competition modes force all conditions on (WPX) or off (HST)
            if value == .wpx {
                Settings.qsb = true; Settings.qrm = true; Settings.qrn = true
                Settings.flutter = true; Settings.lids = true
                Settings.duration = Settings.compDuration
            } else if value == .hst {
                Settings.qsb = false; Settings.qrm = false; Settings.qrn = false
                Settings.flutter = false; Settings.lids = false
                Settings.duration = Settings.compDuration
            }
            SimEngine.shared.uiHooks.onRunState?(value)
            audioBackend.start { [weak contest] in
                contest?.getAudio() ?? [0]
            }
        }
    }

    public func stop() {
        run(.stop)
    }

    /// Called by Contest.getAudio when the run expires or FStopPressed.
    public func handleRunStopped() {
        // Defer the audio stop out of the audio-pump callback: calling
        // AVAudioEngine.stop() synchronously from the fill timer can deadlock
        // with the render thread and freeze the app at end of run. If the
        // user already restarted, skip the stale stop.
        DispatchQueue.main.async { [weak self] in
            guard Settings.runMode == .stop else { return }
            self?.audioBackend.stop()
        }
        SimEngine.shared.uiHooks.onRunState?(.stop)
        // End-of-run score dialog, matching the original:
        //   HST always; WPX only when the time limit expired (not on manual
        //   Stop); all other contests (CQ WW etc.) never.
        // (also off the pump callback so the modal loop cannot be starved)
        let showScore = Settings.simContest == .hst
            || (Settings.simContest == .wpx && SimEngine.shared.runExpired)
        if showScore {
            DispatchQueue.main.async {
                SimEngine.shared.uiHooks.onShowScore?()
            }
        }
    }

    /// Diagnostics for the --smoke self-test mode.
    public var audioDiagnostics: (engineRunning: Bool, playerPlaying: Bool, pending: Int) {
        audioBackend.diagnostics
    }

    // MARK: - message sending

    /// Port of TMainForm.SendMsg.
    public func sendMsg(_ aMsg: StationMessage) {
        guard let contest = Contest.shared else { return }

        if aMsg == .hisCall {
            // retain current callsign, including ''
            contest.setHisCall(enteredCall)
            // update "received" exchange field types (some contests change
            // them based on my call and/or the DX call)
            recvExchTypes = contest.getRecvExchTypes(
                kind: .myStation, myCallsign: contest.me.myCall, dxCallsign: contest.me.hisCall)
            SimEngine.shared.uiHooks.onRecvExchTypes?(recvExchTypes)
        }
        if aMsg == .nr {
            Log.shared.nrSent = true
        }
        contest.me.sendMsg(aMsg)
    }

    // MARK: - entry flows

    /// Port of Edit1KeyPress + the Enter-key QSO flow.
    public func enterKeyPressed() {
        guard let contest = Contest.shared else { return }
        SimEngine.shared.mustAdvance = false   // original ProcessEnter: MustAdvance := false
        _ = contest

        // status bar station info for contests whose exchange is unaffected
        if [.cwt, .fieldDay, .wpx, .cqww, .arrlDx, .iaruHf].contains(Settings.simContest) {
            Log.shared.sbarUpdateStationInfo(enteredCall)
        } else {
            Log.shared.sbarUpdateStationInfo("")
        }

        // no QSO in progress: send CQ
        if enteredCall.isEmpty {
            sendMsg(.cq)
            return
        }

        // update CallSent (HisCall has been sent)
        Contest.shared?.onExchangeEditComplete()

        // has the user entered a complete callsign (3+ chars, no '?')?
        var err = ""
        let validCall = !enteredCall.contains("?")
            && (Contest.shared?.checkEnteredCallLength(enteredCall, &err) ?? false)
        err = ""
        Log.shared.displayError("", isError: false)

        // current state
        let c = Log.shared.callSent
        let n = Log.shared.nrSent
        let q = !enteredExch1.isEmpty || Settings.simContest == .arrlSS
        var r: Bool
        switch Settings.simContest {
        case .arrlSS:
            r = Contest.shared?.validateEnteredExchange(
                call: enteredCall, exch1: enteredExch1, exch2: enteredExch2) == nil
        case .naQp:
            let local = (Contest.shared as? NcjNaQp)?.isCallLocalToContest(enteredCall) ?? false
            r = !enteredExch2.isEmpty || !local
        default:
            r = !enteredExch2.isEmpty
        }

        // send his call if not sent before, or if the call changed
        if !c || (!n && !r) {
            sendMsg(.hisCall)
        }
        if !n && validCall {
            sendMsg(.nr)
        }
        if n && (!r || !q) {
            Log.shared.displayError(err, isError: false)
            sendMsg(.qm)
        }

        if r && q && (c || n) {
            // validate the exchange before sending TU and logging
            var exchError = Contest.shared?.validateEnteredExchange(
                call: enteredCall, exch1: enteredExch1, exch2: enteredExch2)
            if exchError != nil {
                Log.shared.displayError(exchError!, isError: true)
                return
            }
            sendMsg(.tu)
            Log.shared.saveQso(call: enteredCall, exch1: enteredExch1, exch2: enteredExch2)
        } else {
            // original: MustAdvance := true (Advance fires on next envelope end)
            SimEngine.shared.mustAdvance = true
        }
    }

    /// Ctrl/Shift/Alt-Enter: save the QSO without sending TU.
    public func saveQsoShortcut() {
        guard let contest = Contest.shared else { return }
        var err = ""
        if !contest.checkEnteredCallLength(enteredCall, &err) {
            Log.shared.displayError(err, isError: true)
            return
        }
        Log.shared.saveQso(call: enteredCall, exch1: enteredExch1, exch2: enteredExch2)
    }

    /// '.' / '+' / '[' / ',': TU & save.
    public func tuAndSave() {
        guard let contest = Contest.shared else { return }
        var err = ""
        if !contest.checkEnteredCallLength(enteredCall, &err) {
            Log.shared.displayError(err, isError: true)
            return
        }
        Contest.shared?.onExchangeEditComplete()
        if !Log.shared.callSent {
            sendMsg(.hisCall)
        }
        sendMsg(.tu)
        Log.shared.saveQso(call: enteredCall, exch1: enteredExch1, exch2: enteredExch2)
    }

    /// ';': <his> <#>
    public func hisAndNR() {
        Contest.shared?.onExchangeEditComplete()
        sendMsg(.hisCall)
        sendMsg(.nr)
    }

    /// Ctrl-W: wipe boxes.
    public func wipeBoxes() {
        enteredCall = ""
        enteredExch1 = ""
        enteredExch2 = ""
        SimEngine.shared.mustAdvance = false
        if Settings.simContest == .arrlSS {
            Log.shared.setExchangeSummaryText("")
        }
        Contest.shared?.onWipeBoxes()
        Log.shared.callSent = false
        Log.shared.nrSent = false
        SimEngine.shared.uiHooks.onWipeBoxes?()
    }

    /// Esc: abort sending.
    public func abortSend() {
        if Contest.shared?.me.msg.contains(.hisCall) == true {
            Log.shared.callSent = false
        }
        if Contest.shared?.me.msg.contains(.nr) == true {
            Log.shared.nrSent = false
        }
        Contest.shared?.me.abortSend()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

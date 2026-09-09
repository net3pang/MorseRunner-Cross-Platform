// Port of Contest.pas — the contest base class and simulation master.
//
// `Contest` owns the user's station (Me), the station collection, and the
// receive DSP chain (two band-pass filters, modulator, AGC). GetAudio is the
// master per-block tick: it mixes all audio, advances every station, resolves
// completed QSOs against the log, and stops the run when time expires.

import Foundation

public class Contest {
    public nonisolated(unsafe) static var shared: Contest? {
        get { SimEngine.shared.contest }
        set { SimEngine.shared.contest = newValue }
    }

    // ---- simulation state
    public var blockNumber = 0
    public var me = MyStation()
    public var stations = StationCollection()
    var agc = VolumeControl()
    var filt = MovingAverage()
    var filt2 = MovingAverage()
    var modul = Modulator()
    var ritPhase: Float = 0
    var stopPressed = false

    // ---- internal state
    private var lastLoadCallsign = ""
    private var qsoCountSinceStationID = 0
    private var stationIdRate = Settings.stationIdRate
    private var farnsworthEnabled = false
    private var callerStartDelayInBlocks = 0

    // MARK: - lifecycle

    init() {
        setupDSP()
        initContest()
    }

    /// Port of the TContest constructor DSP setup.
    private func setupDSP() {
        filt.points = bankersRound(0.7 * Float(AudioConstants.defaultRate) / Float(Settings.bandWidth))
        filt.passes = 3
        filt.samplesInInput = Settings.bufSize
        filt.gainDb = 10 * log10(500 / Float(Settings.bandWidth))

        filt2.points = filt.points   // must match filt or swapping changes bandwidth
        filt2.passes = filt.passes
        filt2.samplesInInput = filt.samplesInInput
        filt2.gainDb = filt.gainDb

        modul.samplesPerSec = AudioConstants.defaultRate
        modul.carrierFreq = Float(Settings.pitch)

        agc.noiseInDb = 76
        agc.noiseOutDb = 76
        agc.setAttackSamples(155)   // AGC attack 5 ms
        agc.setHoldSamples(155)
        agc.setAgcEnabled(true)
        initContest()
    }

    /// Port of TContest.Init.
    func initContest() {
        me.initStation()
        stations.removeAll()
        blockNumber = 0
        lastLoadCallsign = ""
        qsoCountSinceStationID = 0
        farnsworthEnabled = false
        Settings.noActivityCnt = 0   // original TContest.Init resets this
        // A contest can also be driven directly by the headless engine/tests,
        // so reset the per-run stop guards here as well as in SimController.
        SimEngine.shared.stopHandled = false
        SimEngine.shared.stopRequested = false
        SimEngine.shared.runExpired = false
        callerStartDelayInBlocks = RndFunc.secondsToBlocks(Float(Settings.singleCallStartDelay) / 1000) + 5
    }

    // MARK: - abstract contest hooks (must be overridden)

    func loadCallHistory(_ userCallsign: String) -> Bool { fatalError("abstract") }
    func pickStation() -> Int { fatalError("abstract") }
    func dropStation(_ id: Int) { fatalError("abstract") }
    func getCall(_ id: Int) -> String { fatalError("abstract") }
    func getExchange(_ id: Int, into station: DxStation) { fatalError("abstract") }

    // MARK: - helpers

    func getRandomSerialNR() -> Int {
        Settings.serialNRSettings[Settings.serialNR]?.getNR() ?? 1
    }

    func getStationInfo(_ callsign: String) -> String {
        Dxcc.shared.stationInfo(callsign)
    }

    /// Helper for QrnStation: a single random callsign.
    func pickCallOnly() -> String {
        let id = pickStation()
        return getCall(id)
    }

    /// Port of TContest.IsReloadRequired.
    func isReloadRequired(_ userCallsign: String) -> Bool {
        !(userCallsign.isEmpty || lastLoadCallsign == userCallsign)
    }

    func setLastLoadCallsign(_ userCallsign: String) {
        lastLoadCallsign = userCallsign
    }

    var isFarnsworthAllowed: Bool { farnsworthEnabled }

    func setFarnsworthEnabled(_ v: Bool) { farnsworthEnabled = v }

    /// Port of TContest.OnSetMyCall.
    @discardableResult
    func onSetMyCall(_ userCallsign: String) -> Bool {
        me.myCall = userCallsign
        me.sentExchTypes = getSentExchTypes(kind: .myStation, callsign: userCallsign)
        return true
    }

    /// Port of TContest.ValidateMyExchange.
    func validateMyExchange(_ exchange: String, tokens: inout [String]) -> String? {
        let exchTypes = me.sentExchTypes
        tokens = exchange.split(separator: " ").map(String.init)
        if tokens.isEmpty { tokens = ["", ""] }
        if tokens.count == 1 { tokens.append("") }
        let field1 = exchange1Settings[exchTypes.exch1]
        let field2 = exchange2Settings[exchTypes.exch2]
        let ok = validateExchField(field1, tokens[0]) && validateExchField(field2, tokens[1])
        if !ok {
            return "Invalid exchange: '\(exchange)' - expecting \(Settings.activeContest.msg)."
        }
        return nil
    }

    /// Validate a value against a field definition regex (Delphi
    /// `ValidateExchField`), anchored as `^(R)$`.
    func validateExchField(_ def: FieldDefinition?, _ value: String) -> Bool {
        guard let def else { return false }
        if Settings.simContest == .naQp {
            // special case: optional empty string (e.g. '()|([0-9A-Z/]*)')
            if def.regex.hasPrefix("()|(") && value.isEmpty {
                return true
            }
        }
        guard let regex = try? NSRegularExpression(pattern: "^(" + def.regex + ")$") else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    /// Port of TContest.OnContestPrepareToStart.
    @discardableResult
    func onContestPrepareToStart(_ userCallsign: String, sentExchange: String) -> Bool {
        if isReloadRequired(userCallsign) {
            let result = loadCallHistory(userCallsign)
            if result {
                setLastLoadCallsign(userCallsign)
            }
            return result
        }
        return true
    }

    public func serialNrModeChanged() {
        assert(Settings.runMode != .stop)
    }

    // MARK: - exchange types

    func getSentExchTypes(kind: StationKind, callsign: String) -> ExchTypes {
        getExchangeTypes(kind: kind, requestedMsgType: .sendMsg, stationCallsign: callsign, remoteCallsign: "")
    }

    func getRecvExchTypes(kind: StationKind, myCallsign: String, dxCallsign: String) -> ExchTypes {
        if kind == .myStation {
            return getExchangeTypes(kind: kind, requestedMsgType: .recvMsg, stationCallsign: myCallsign, remoteCallsign: dxCallsign)
        }
        return getExchangeTypes(kind: kind, requestedMsgType: .recvMsg, stationCallsign: dxCallsign, remoteCallsign: myCallsign)
    }

    func getExchangeTypes(kind: StationKind, requestedMsgType: RequestedMsgType,
                          stationCallsign: String, remoteCallsign: String) -> ExchTypes {
        ExchTypes(exch1: Settings.activeContest.exchType1, exch2: Settings.activeContest.exchType2)
    }

    // MARK: - messages

    /// Port of TContest.SendMsg: map message classes to text templates.
    func sendMsg(_ stn: Station, _ aMsg: StationMessage) {
        switch aMsg {
        case .cq: sendText(stn, "CQ <my> TEST")
        case .nr: sendText(stn, "<#>")
        case .tu:
            // station ID after 3 consecutive QSOs (>= StationIdRate-1 since the
            // counter increments after 'TU <my>' has been sent)
            if (Settings.runMode == .pileup || Settings.runMode == .wpx)
                && stationIdRate > 0 && qsoCountSinceStationID >= (stationIdRate - 1) {
                sendText(stn, "TU <my>")
            } else {
                sendText(stn, "TU")
            }
        case .myCall: sendText(stn, "<my>")
        case .hisCall: sendText(stn, "<his>")
        case .b4: sendText(stn, "QSO B4")
        case .qm: sendText(stn, "?")
        case .nil_:
            if Settings.f8.isEmpty { sendText(stn, "NIL") } else { sendText(stn, Settings.f8) }
        case .rNR: sendText(stn, "R <#>")
        case .rNR2: sendText(stn, "R <#> <#>")
        case .deMyCall1: sendText(stn, "DE <my>")
        case .deMyCall2: sendText(stn, "DE <my> <my>")
        case .deMyCallNr1: sendText(stn, "DE <my> <#>")
        case .deMyCallNr2: sendText(stn, "DE <my> <my> <#>")
        case .myCall2: sendText(stn, "<my> <my>")
        case .myCallNr1: sendText(stn, "<my> <#>")
        case .myCallNr2: sendText(stn, "<my> <my> <#>")
        case .nrQm: sendText(stn, "NR?")
        case .longCQ: sendText(stn, "CQ CQ TEST <my> <my> TEST")
        case .qrl: sendText(stn, "QRL?")
        case .qrl2: sendText(stn, "QRL?   QRL?")
        case .qsy: sendText(stn, "<his>  QSY QSY")
        case .agn: sendText(stn, "AGN")
        case .garbage, .none: break
        }
    }

    func sendText(_ stn: Station, _ aMsg: String) {
        stn.sendText(aMsg)
    }

    // MARK: - QSO state

    func resetQsoState() {
        me.hisCall = ""
    }

    func onWipeBoxes() {
        Log.shared.nrSent = false
        Log.shared.displayError("", isError: false)
    }

    @discardableResult
    func onExchangeEdit(call: String, exch1: String, exch2: String) -> (summary: String, error: String) {
        (summary: "", error: "")
    }

    func onExchangeEditComplete() {
        let call = SimEngine.shared.uiHooks.enteredCall
        Log.shared.callSent = !call.isEmpty && call == me.hisCall
    }

    func setHisCall(_ call: String) {
        if !call.isEmpty {
            me.hisCall = call
        }
        Log.shared.callSent = !call.isEmpty
    }

    /// Simple length check: 3+ characters after stripping '?'.
    func checkEnteredCallLength(_ call: String, _ error: inout String) -> Bool {
        let ok = call.replacingOccurrences(of: "?", with: "").count >= 3
        if !ok {
            error = "Invalid callsign"
        }
        return ok
    }

    /// Per-type minimum length validation of the entered exchange.
    func validateEnteredExchange(call: String, exch1: String, exch2: String) -> String? {
        let recv = SimEngine.shared.uiHooks.recvExchTypes
        var error: String? = nil
        // validate Exchange 1 (Edit2)
        switch recv.exch1 {
        case .rst: if exch1.count != 3 { error = "Missing/Invalid \(exchange1Settings[.rst]?.caption ?? "RST")" }
        case .opName: if exch1.count <= 1 { error = "Missing/Invalid \(exchange1Settings[.opName]?.caption ?? "Name")" }
        case .fdClass: if exch1.count <= 1 { error = "Missing/Invalid \(exchange1Settings[.fdClass]?.caption ?? "Class")" }
        case .ssNrPrecedence, .undef: break
        }
        // validate Exchange 2 (Edit3)
        if error == nil {
            switch recv.exch2 {
            case .serialNr, .genericField, .cqZone, .ituZone, .power, .naQpExch2:
                if exch2.count <= 0 { error = "Missing/Invalid \(exchange2Settings[recv.exch2]?.caption ?? "Exch")" }
            case .arrlSection, .stateProv:
                if exch2.count <= 1 { error = "Missing/Invalid \(exchange2Settings[recv.exch2]?.caption ?? "Exch")" }
            case .jaPref:
                if exch2.count <= 2 { error = "Missing/Invalid \(exchange2Settings[.jaPref]?.caption ?? "Number")" }
            case .jaCity:
                if exch2.count <= 3 { error = "Missing/Invalid \(exchange2Settings[.jaCity]?.caption ?? "Number")" }
            case .naQpNonNaExch2:
                break  // length >= 0 always true
            case .ssCheckSection, .age, .undef:
                break
            }
        }
        return error
    }

    /// Save the entered exchange into a QSO (Delphi `SaveEnteredExchToQso`).
    func saveEnteredExchToQso(_ qso: Qso, _ exch1: String, _ exch2: String) {
        let recv = SimEngine.shared.uiHooks.recvExchTypes
        switch recv.exch1 {
        case .rst: qso.rst = Int(exch1) ?? 0
        case .opName, .fdClass: qso.exch1 = exch1
        case .ssNrPrecedence, .undef: break
        }
        switch recv.exch2 {
        case .serialNr: qso.nr = Int(exch2) ?? 0
        case .genericField, .arrlSection, .stateProv, .cqZone, .ituZone,
             .power, .jaPref, .jaCity, .naQpExch2:
            qso.exch2 = exch2
        case .naQpNonNaExch2:
            qso.exch2 = exch2.isEmpty ? "DX" : exch2
        case .ssCheckSection, .age, .undef:
            break
        }
        if qso.exch1.isEmpty { qso.exch1 = "?" }
        if qso.exch2.isEmpty && recv.exch2 != .naQpNonNaExch2 {
            qso.exch2 = "?"
        }
    }

    /// Port of TContest.FindQsoErrors.
    func findQsoErrors(_ qso: Qso, _ corrections: inout [String]) {
        qso.checkExch1(&corrections)
        qso.checkExch2(&corrections)
    }

    /// Scoring hook: sets Qso.Points and returns the multiplier string.
    func extractMultiplier(_ qso: Qso) -> String {
        qso.points = 1
        return qso.pfx
    }

    /// Minutes elapsed in the run (Delphi `Minute`).
    var minute: Float {
        RndFunc.blocksToSeconds(Float(blockNumber)) / 60
    }

    // MARK: - caller management

    private func dxCount() -> Int {
        var result = 0
        for i in stride(from: stations.count - 1, through: 0, by: -1) {
            if let dx = stations[i] as? DxStation, dx.oper.state != .done {
                result += 1
            }
        }
        return result
    }

    private func swapFilters() {
        let f = filt
        filt = filt2
        filt2 = f
        filt2.reset()
    }

    // MARK: - the master tick

    /// Generate one audio block and advance the simulation (port of
    /// `TContest.GetAudio`). Called once per audio block (~46 ms).
    func getAudio() -> SampleArray {
        let noiseAmp: Float = 6000
        var result: SampleArray = [0]

        // The audio backend can make a few callbacks while it is winding down
        // after a stop.  Once the run is stopped, do not tick stations or emit
        // any more receive/transmit audio from those callbacks.
        if Settings.runMode == .stop {
            return result
        }

        blockNumber += 1

        // Check the limit before mixing audio or advancing any station.  This
        // makes the block at the deadline silent and prevents a partially sent
        // message from being completed (and its QSO from being verified) after
        // time has expired.
        let timeExpired = RndFunc.blocksToSeconds(Float(blockNumber)) >= Float(Settings.duration) * 60
        let stopRequested = SimEngine.shared.stopRequested
        if timeExpired || stopRequested {
            // Preserve the final clock display from the normal end-of-block
            // path even though no audio or station tick is allowed at the
            // deadline.
            SimEngine.shared.uiHooks.onClockUpdate?(clockText())
            finishRun(timeExpired: timeExpired && !stopRequested)
            return result
        }

        if blockNumber < 6 { return result }

        // complex noise
        var reIm = ReImArrays()
        reIm.setLength(Settings.bufSize)
        for i in 0..<reIm.re.count {
            reIm.re[i] = 3 * noiseAmp * (Float.random(in: 0..<1) - 0.5)
            reIm.im[i] = 3 * noiseAmp * (Float.random(in: 0..<1) - 0.5)
        }

        // QRN
        if Settings.qrn {
            for i in 0..<reIm.re.count {
                if Float.random(in: 0..<1) < 0.01 {
                    reIm.re[i] = 60 * noiseAmp * (Float.random(in: 0..<1) - 0.5)
                }
            }
            if Float.random(in: 0..<1) < 0.01 {
                stations.addQrn()
            }
        }

        // QRM
        if Settings.qrm && Float.random(in: 0..<1) < 0.0002 {
            stations.addQrm()
        }

        // audio from stations
        for stn in 0..<stations.count where stations[stn].state == .sending {
            let blk = stations[stn].getBlock()
            for i in 0..<blk.count {
                let bfo = stations[stn].bfo - ritPhase
                    - Float(i) * Float(AudioConstants.twoPi) * Float(Settings.rit) / Float(AudioConstants.defaultRate)
                reIm.re[i] += blk[i] * cos(bfo)
                reIm.im[i] -= blk[i] * sin(bfo)
            }
        }

        // RIT
        ritPhase += Float(Settings.bufSize) * Float(AudioConstants.twoPi) * Float(Settings.rit) / Float(AudioConstants.defaultRate)
        while ritPhase > Float(AudioConstants.twoPi) { ritPhase -= Float(AudioConstants.twoPi) }
        while ritPhase < -Float(AudioConstants.twoPi) { ritPhase += Float(AudioConstants.twoPi) }

        // my audio (self-monitor)
        if me.state == .sending {
            let blk = me.getBlock()
            var smg = pow(10, (SimEngine.shared.uiHooks.volume - 1) * 3)
            // linear rolloff towards zero between -57 and -60 dB (Smg=0 @ -60dB)
            if SimEngine.shared.uiHooks.volume < 0.05 {
                smg *= SimEngine.shared.uiHooks.volume * 60
            }
            var rfg: Float = 1
            if Settings.qsk {
                for i in 0..<blk.count {
                    if rfg > (1 - smg * blk[i] / me.amplitude) {
                        rfg = 1 - smg * blk[i] / me.amplitude
                    } else {
                        rfg = rfg * 0.997 + 0.003
                    }
                    reIm.re[i] = smg * blk[i] + rfg * reIm.re[i]
                    reIm.im[i] = smg * blk[i] + rfg * reIm.im[i]
                }
            } else {
                for i in 0..<blk.count {
                    reIm.re[i] = smg * blk[i]
                    reIm.im[i] = smg * blk[i]
                }
            }
        }

        // LPF
        _ = filt2.filter(reIm)
        reIm = filt.filter(reIm)
        if blockNumber % 10 == 0 {
            swapFilters()
        }

        // mix up to the pitch frequency
        result = modul.modulate(reIm)
        // AGC
        result = agc.process(result)
        // optional WAV recording hook
        SimEngine.shared.uiHooks.onOutputBlock?(result)

        // timer tick
        me.tick()
        for stn in stride(from: stations.count - 1, through: 0, by: -1) {
            stations[stn].tick()
        }

        // if DX is done, write to log and kill
        if !Log.shared.qsoList.isEmpty {
            for i in stride(from: stations.count - 1, through: 0, by: -1) {
                if let dx = stations[i] as? DxStation,
                   dx.oper.state == .done,
                   [.yes, .almost].contains(dx.oper.callConfidenceCheck(Log.shared.qsoList.last!.call, randomResult: false)) {
                    // grab the Qso's "True" data and delete this DX station
                    dx.dataToLastQso()
                    // Me.HisCall cleared for the next QSO
                    resetQsoState()
                    // rerun error check and update the on-screen log
                    Log.shared.checkErr()
                    if Settings.simContest == .hst {
                        Log.shared.updateStatsHst()
                    } else {
                        Log.shared.updateStats(verifyResults: true)
                    }
                }
            }
        }

        // show info
        Log.shared.showRate()
        SimEngine.shared.uiHooks.onClockUpdate?(clockText())
        if Settings.runMode == .pileup {
            SimEngine.shared.uiHooks.onPileupCount?(dxCount())
        }

        if Settings.runMode == .single && dxCount() == 0 && blockNumber > callerStartDelayInBlocks {
            me.msg = .cq  // no need to send CQ in this mode
            stations.addCaller()?.processEvent(.meFinished)
        } else if Settings.runMode == .hst && dxCount() < Settings.activity {
            me.msg = .cq
            let count = Settings.activity - dxCount()
            if count > 0 {
                for _ in 1...count {
                    stations.addCaller()?.processEvent(.meFinished)
                }
            }
        }

        return result
    }

    /// Stop every station and finalize the run exactly once.
    private func finishRun(timeExpired: Bool) {
        guard !SimEngine.shared.stopHandled else { return }

        SimEngine.shared.stopHandled = true
        if timeExpired {
            SimEngine.shared.runExpired = true
        }

        // Do not use MyStation.abortSend(): it emits `.msgSent`, which can
        // spawn callers or otherwise advance a QSO after the deadline.
        me.stopTransmission()
        for station in stations.items {
            station.stopTransmission()
        }

        if timeExpired {
            // A QSO saved immediately before the deadline may still have no
            // true callsign because the matching DX station did not finish.
            // Re-check it now so it is displayed and scored as NIL/error,
            // never as a verified QSO.  No DX data is copied after expiry.
            Log.shared.checkErr()
            if Settings.simContest == .hst {
                Log.shared.updateStatsHst()
            } else {
                Log.shared.updateStats(verifyResults: true)
            }
        }

        Settings.runMode = .stop
        SimEngine.shared.stopRequested = false
        SimEngine.shared.uiHooks.onRunStopped?()
    }

    private func clockText() -> String {
        let totalSeconds = Int(RndFunc.blocksToSeconds(Float(blockNumber)))
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // MARK: - engine -> station events

    func onMeFinishedSending() {
        var msg: StationMessages = []

        // reset the Station ID counter after sending a CQ or 3 consecutive QSOs
        if me.msg.contains(.cq) || (me.msg.contains(.tu) && qsoCountSinceStationID >= stationIdRate) {
            onStationIDSent()
        }

        // the stations heard my CQ and want to call
        if !(Settings.runMode == .single || Settings.runMode == .hst)
            && RndFunc.blocksToSeconds(Float(blockNumber)) < Float(Settings.duration) * 60 {
            if me.msg.contains(.cq) || (!Log.shared.qsoList.isEmpty && (me.msg.contains(.tu) || me.msg.contains(.myCall))) {
                var z = 0
                var dx = dxCount()
                if !me.msg.contains(.cq) && dx > 0 {
                    dx -= 1  // the just-finished QSO has to be deducted
                }
                let count = RndFunc.poisson(mean: Float(Settings.activity) / 2) - dx
                if count > 0 {
                    for _ in 1...count {
                        stations.addCaller()
                        z = 1
                    }
                }
                if z == 0 {
                    // at most 3 CQ's without contesters
                    Settings.noActivityCnt += 1
                    if Settings.noActivityCnt > 2 || Settings.noStopActivity > 0 {
                        stations.addCaller()
                        Settings.noActivityCnt = 0
                    }
                }
            }
        }

        // update caller's confidence metric
        if me.msg.contains(.hisCall) {
            stations.findBestMatches(me.hisCall)
        }

        if Settings.nilInstantRemove && me.msg.contains(.nil_) {
            if let dropped = stations.dropCallerForNil() {
                if dropped.active || Settings.runMode == .single {
                    SimEngine.shared.uiHooks.onStatusBar?("Skipped \(dropped.call)", false)
                }
            }
            msg = me.msg
            me.msg = .garbage
        }

        // tell callers that I finished sending
        for i in stride(from: stations.count - 1, through: 0, by: -1) {
            stations[i].processEvent(.meFinished)
        }

        if msg != [] {
            me.msg = msg
        }
    }

    func onMeStartedSending() {
        // tell callers that I started sending
        for i in stride(from: stations.count - 1, through: 0, by: -1) {
            stations[i].processEvent(.meStarted)
        }
    }

    func onSaveQsoComplete() {
        qsoCountSinceStationID += 1
    }

    func onStationIDSent() {
        qsoCountSinceStationID = 0
    }

    // MARK: - DX station true-data logging

    /// Port of TDxStation.DataToLastQso body: copy the DX station's true
    /// data into the last QSO.
    func logDxStationData(_ station: DxStation) {
        guard let qso = Log.shared.qsoList.last else { return }
        qso.trueCall = station.myCall
        qso.trueRst = station.rst
        qso.trueNr = station.nr
        switch station.sentExchTypes.exch1 {
        case .rst: qso.trueExch1 = String(station.rst)
        case .opName: qso.trueExch1 = station.opName
        case .fdClass: qso.trueExch1 = station.exch1
        case .ssNrPrecedence:
            qso.trueNr = station.nr
            qso.truePrec = station.prec
        case .undef: break
        }
        switch station.sentExchTypes.exch2 {
        case .serialNr: qso.trueExch2 = String(station.nr)
        case .genericField, .cqZone, .ituZone, .arrlSection, .stateProv,
             .power, .jaPref, .jaCity, .naQpExch2, .naQpNonNaExch2:
            qso.trueExch2 = station.exch2
        case .ssCheckSection:
            qso.trueCheck = station.chk
            qso.trueSect = station.sect
        case .age, .undef: break
        }
    }
}

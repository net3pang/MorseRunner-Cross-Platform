// Port of Log.pas — the QSO log, score statistics, and error checking.

import Foundation

/// QSO error codes (Delphi `TLogError`).
public enum LogError: Int {
    case none = 0, nil_, dup, call, rst, name, cls, nr, sec, qth, zn, soc, st, pwr, err, prec, chk

    public var display: String {
        switch self {
        case .none: return ""
        case .nil_: return "NIL"
        case .dup: return "DUP"
        case .call: return "CALL"
        case .rst: return "RST"
        case .name: return "NAME"
        case .cls: return "CL"
        case .nr: return "NR"
        case .sec: return "SEC"
        case .qth: return "QTH"
        case .zn: return "ZN"
        case .soc: return "SOC"
        case .st: return "ST"
        case .pwr: return "PWR"
        case .err: return "ERR"
        case .prec: return "PREC"
        case .chk: return "CHK"
        }
    }
}

/// One logged QSO (port of `TQso`; class for reference semantics).
public final class Qso {
    public var t: Double = 0                    // seconds-of-day / 86400
    public var call = ""
    public var trueCall = ""
    public var rawCallsign = ""
    public var rst = 0
    public var trueRst = 0
    public var nr = 0
    public var trueNr = 0
    public var prec = ""
    public var truePrec = ""
    public var check = 0
    public var trueCheck = 0
    public var sect = ""
    public var trueSect = ""
    public var exch1 = ""
    public var trueExch1 = ""
    public var exch2 = ""
    public var trueExch2 = ""
    public var trueWpm = ""
    public var pfx = ""
    public var multStr = ""
    public var points = 1
    public var dupe = false
    public var exchError: LogError = .none
    public var exch1Error: LogError = .none
    public var exch1ExError: LogError = .none
    public var exch2Error: LogError = .none
    public var exch2ExError: LogError = .none
    public var err = ""
    public var columnErrorFlags = 0

    public func setColumnErrorFlag(_ columnIdx: Int) {
        if columnIdx >= 0 {
            columnErrorFlags |= (1 << columnIdx)
        }
    }

    public func testColumnErrorFlag(_ columnIdx: Int) -> Bool {
        (columnErrorFlags & (1 << columnIdx)) != 0
    }

    /// Port of `TQso.CheckExch1`.
    public func checkExch1(_ corrections: inout [String]) {
        exch1Error = .none
        exch1ExError = .none
        let recv = SimEngine.shared.uiHooks.recvExchTypes
        switch recv.exch1 {
        case .rst:
            if trueRst != rst { exch1Error = .rst }
        case .opName:
            if trueExch1 != exch1 { exch1Error = .name }
        case .fdClass:
            if trueExch1 != exch1 { exch1Error = .cls }
        case .ssNrPrecedence:
            // For ARRL SS, exchange 1 tests the raw NR and Prec values
            if trueNr != nr { exch1Error = .nr }
            if truePrec != prec { exch1ExError = .prec }
        case .undef:
            break
        }
        switch exch1Error {
        case .none: break
        case .rst: corrections.append(String(trueRst))
        case .nr: corrections.append(String(trueNr))
        default: corrections.append(trueExch1)
        }
        if exch1ExError == .prec {
            corrections.append(truePrec)
        }
    }

    /// Reduce power characters (T, O, A, N) to (0, 0, 1, 9).
    private func reducePowerStr(_ text: String) -> String {
        var r = text.replacingOccurrences(of: "T", with: "0")
        r = r.replacingOccurrences(of: "O", with: "0")
        r = r.replacingOccurrences(of: "A", with: "1")
        r = r.replacingOccurrences(of: "N", with: "9")
        return r
    }

    private func reduceNumeric(_ text: String) -> Int {
        Int(reducePowerStr(text)) ?? 0
    }

    /// Port of `TQso.CheckExch2`.
    public func checkExch2(_ corrections: inout [String]) {
        exch2Error = .none
        exch2ExError = .none
        let recv = SimEngine.shared.uiHooks.recvExchTypes
        switch recv.exch2 {
        case .serialNr:
            if trueNr != nr { exch2Error = .nr }
        case .genericField:
            switch Settings.simContest {
            case .cwt:
                if trueExch2 != exch2 {
                    exch2Error = Settings.isNum(trueExch2) ? .nr : .qth
                }
            case .sst:
                if trueExch2 != exch2 { exch2Error = .qth }
            case .iaruHf:
                if trueExch2 != exch2 {
                    exch2Error = Settings.isNum(trueExch2) ? .zn : .soc
                }
            default:
                if trueExch2 != exch2 { exch2Error = .err }
            }
        case .cqZone:
            if reduceNumeric(trueExch2) != reduceNumeric(exch2) { exch2Error = .zn }
        case .arrlSection:
            if trueExch2 != exch2 { exch2Error = .sec }
        case .stateProv:
            if trueExch2 != exch2 { exch2Error = .st }
        case .ituZone:
            if trueExch2 != exch2 { exch2Error = .zn }
        case .power:
            if reducePowerStr(trueExch2) != reducePowerStr(exch2) { exch2Error = .pwr }
        case .jaPref, .jaCity:
            if trueExch2 != exch2 { exch2Error = .nr }
        case .naQpExch2:
            if trueExch2 != exch2 { exch2Error = .st }
        case .naQpNonNaExch2:
            // Non-NA stations do not send a location (typically logged as DX)
            if !(trueExch2 == exch2 || (exch2 == "DX" && trueExch2.isEmpty)) {
                exch2Error = .st
            }
        case .ssCheckSection:
            if trueCheck != check { exch2Error = .chk }
            if trueSect != sect { exch2ExError = .sec }
        case .age, .undef:
            break
        }

        switch exch2Error {
        case .none: break
        case .nr:
            if Settings.simContest == .hst && Settings.runMode == .hst {
                corrections.append(String(format: "%04d", trueNr))
            } else if Settings.simContest == .arrlSS {
                corrections.append(trueSect)
            } else {
                corrections.append(trueExch2)
            }
        case .chk:
            corrections.append(String(format: "%02d", trueCheck))
        case .st:
            // NAQP non-NA: return a space to avoid a confusing "" in the log
            if Settings.simContest == .naQp && recv.exch2 == .naQpNonNaExch2 && trueExch2.isEmpty {
                corrections.append(" ")
            } else {
                corrections.append(trueExch2)
            }
        default:
            corrections.append(trueExch2)
        }
        if exch2ExError == .sec {
            corrections.append(trueSect)
        }
    }
}

/// The QSO log and score statistics (port of the Log unit state).
public final class Log {
    public nonisolated(unsafe) static let shared = Log()

    public var qsoList: [Qso] = []
    /// Sorted, dup-free multiplier lists.
    public var rawMultList: [String] = []
    public var verifiedMultList: [String] = []
    public var rawPoints = 0
    public var verifiedPoints = 0

    // ---- entry-state flags
    /// msgHisCall has been sent; cleared upon edit.
    public var callSent = false
    /// msgNR has been sent; cleared after QSO completion.
    public var nrSent = false

    // ---- status bar state
    public var sbarDebugMsg = ""
    public var sbarStationInfo = ""
    public var exchangeSummaryText = ""
    public var sbarErrorMsg = ""
    public var sbarErrorColor = false  // true = red

    // ---- column indices for error flags
    public var callColumnInx = -1
    public var exch1ColumnInx = 2
    public var exch1ExColumnInx = -1
    public var exch2ColumnInx = 3
    public var exch2ExColumnInx = -1
    public var correctionColumnInx = -1

    private init() {}

    // MARK: - mult list

    public func applyMults(_ multipliers: String, to list: inout [String]) {
        for m in multipliers.components(separatedBy: ";") where !m.isEmpty {
            if !list.contains(m) {
                list.append(m)
                list.sort()
            }
        }
    }

    // MARK: - QSO save

    /// Port of `Log.SaveQso`. Returns false when the callsign was rejected.
    @discardableResult
    public func saveQso(call: String, exch1: String, exch2: String) -> Bool {
        let cleanedCall = call.replacingOccurrences(of: "?", with: "")
        guard let contest = Contest.shared else { return false }

        // verify callsign (simple length check)
        var exchError = ""
        if !contest.checkEnteredCallLength(cleanedCall, &exchError) {
            displayError(exchError, isError: true)
            return false
        }

        let qso = Qso()
        qso.t = Double(RndFunc.blocksToSeconds(Float(contest.blockNumber))) / 86400
        qso.call = cleanedCall

        // save contest-specific exchange values
        contest.saveEnteredExchToQso(qso, exch1, exch2)

        qso.points = 1
        qso.rawCallsign = CallsignUtils.extractCallsign(qso.call)
        qso.pfx = CallsignUtils.extractPrefix(qso.call)
        qso.multStr = contest.extractMultiplier(qso)
        if Settings.simContest == .hst {
            qso.pfx = String(callToScore(qso.call))
        }

        // mark if dupe
        qso.dupe = qsoList.contains { $0.call == qso.call && $0.err == "   " }

        // find Wpm from the DX's log
        for i in stride(from: contest.stations.count - 1, through: 0, by: -1) {
            if let dx = contest.stations[i] as? DxStation,
               [.yes, .almost].contains(dx.oper.callConfidenceCheck(qso.call, randomResult: false)) {
                qso.trueWpm = dx.wpmAsText()
                break
            }
        }

        // what's in the DX's log?
        for i in stride(from: contest.stations.count - 1, through: 0, by: -1) {
            if let dx = contest.stations[i] as? DxStation,
               dx.oper.state == .done,
               [.yes, .almost].contains(dx.oper.callConfidenceCheck(qso.call, randomResult: false)) {
                dx.dataToLastQso()  // grab "True" data and delete this dx station
                contest.resetQsoState()
                break
            }
        }

        qsoList.append(qso)
        checkErr()
        lastQsoToScreen()
        if Settings.simContest == .hst {
            updateStatsHst()
        } else {
            updateStats(verifyResults: false)
        }

        // clear entry fields and QSO state (original: SaveQso -> WipeBoxes;
        // clears enteredCall/exch1/exch2 and CallSent/NrSent, otherwise the
        // stale RST=599/NR values trigger a bogus save on the next call).
        SimController.shared.wipeBoxes()

        // increment my serial NR
        let myExch = contest.me.sentExchTypes
        if myExch.exch1 == .ssNrPrecedence || myExch.exch2 == .serialNr {
            contest.me.nr += 1
        }

        contest.onSaveQsoComplete()
        return true
    }

    /// Port of `Log.CallToScore`.
    public func callToScore(_ s: String) -> Int {
        let encoded = Keyer.shared.encode(s)
        var result = -1
        for ch in encoded {
            switch ch {
            case ".": result += 2
            case "-": result += 4
            case " ": result += 2
            default: break
            }
        }
        return result
    }

    // MARK: - stats

    public func updateStats(verifyResults: Bool) {
        if !verifyResults, let last = qsoList.last {
            rawPoints += last.points
            applyMults(last.multStr, to: &rawMultList)
        } else if verifyResults {
            // Recalculate the verified score from error-free QSOs only
            // (original: "if Err = '   ' then Inc(VerifiedPoints, Points)").
            verifiedPoints = 0
            verifiedMultList = []
            for qso in qsoList where qso.err == "   " {
                verifiedPoints += qso.points
                applyMults(qso.multStr, to: &verifiedMultList)
            }
        }
        let mul = rawMultList.count
        SimEngine.shared.uiHooks.onStatsUpdate?(ScoreSummary(
            qsoCount: qsoList.count,
            verifiedQsoCount: qsoList.filter { $0.err == "   " }.count,
            points: rawPoints, mults: mul,
            verifiedPoints: verifiedPoints, verifiedMults: verifiedMultList.count))
    }

    public func updateStatsHst() {
        var rawScore = 0
        var score = 0
        for qso in qsoList {
            let callScore = callToScore(qso.call)
            rawScore += callScore
            if qso.err == "   " {
                score += callScore
            }
        }
        SimEngine.shared.uiHooks.onStatsUpdate?(ScoreSummary(
            qsoCount: qsoList.count,
            verifiedQsoCount: qsoList.filter { $0.err == "   " }.count,
            points: rawScore, mults: 0, verifiedPoints: score, verifiedMults: 0))
        SimEngine.shared.uiHooks.onHstScore?(score)
    }

    /// Port of `Log.ShowRate` (qso/hr over the last 5 minutes).
    public func showRate() {
        let t = Double(RndFunc.blocksToSeconds(Float(Contest.shared?.blockNumber ?? 0))) / 86400
        if t == 0 { return }
        let d = min(5.0 / 1440.0, t)
        var cnt = 0
        for i in stride(from: qsoList.count - 1, through: 0, by: -1) {
            if Double(qsoList[i].t) > (t - d) {
                cnt += 1
            } else {
                break
            }
        }
        SimEngine.shared.uiHooks.onRateUpdate?(Int((Double(cnt) / d / 24).rounded()))
    }

    // MARK: - error checking

    public func checkErr() {
        guard let qso = qsoList.last else { return }
        var corrections: [String] = []

        if qso.trueCall == "" {
            qso.exchError = .nil_
        } else if qso.trueCall != qso.call {
            qso.exchError = .call
            corrections.append(qso.trueCall)
        } else if qso.dupe && !showCorrections {
            qso.exchError = .dup
        } else {
            qso.exchError = .none
        }

        Contest.shared?.findQsoErrors(qso, &corrections)

        qso.columnErrorFlags = 0

        if qso.exchError == .nil_ || qso.exchError == .dup {
            qso.err = qso.exchError.display
            if qso.exchError != .dup {
                qso.setColumnErrorFlag(correctionColumnInx)
            }
        } else if showCorrections {
            if qso.dupe {
                corrections.insert(LogError.dup.display, at: 0)
            }
            qso.err = corrections.joined(separator: " ")
            if qso.exchError != .none { qso.setColumnErrorFlag(callColumnInx) }
            if qso.exch1Error != .none { qso.setColumnErrorFlag(exch1ColumnInx) }
            if qso.exch1ExError != .none { qso.setColumnErrorFlag(exch1ExColumnInx) }
            if qso.exch2Error != .none { qso.setColumnErrorFlag(exch2ColumnInx) }
            if qso.exch2ExError != .none { qso.setColumnErrorFlag(exch2ExColumnInx) }
        } else {
            if qso.exch1Error != .none {
                qso.err = qso.exch1Error.display
            } else if qso.exch2Error != .none {
                qso.err = qso.exch2Error.display
            } else if qso.exch1ExError != .none {
                qso.err = qso.exch1ExError.display
            } else if qso.exch2ExError != .none {
                qso.err = qso.exch2ExError.display
            } else {
                qso.err = ""
            }
            qso.setColumnErrorFlag(correctionColumnInx)
        }

        if qso.err.isEmpty {
            qso.err = "   "
        }
        refreshLastRow()
    }

    /// Port of `Log.ShowCorrections` (correction column for all but HST).
    public var showCorrections: Bool {
        Settings.simContest != .hst
    }

    // MARK: - screen updates

    public func lastQsoToScreen() {
        guard let qso = qsoList.last else { return }
        SimEngine.shared.uiHooks.onScoreTableInsert?(scoreTableRow(for: qso))
    }

    /// Build one score-table row (original Log.ScoreTableInsert columns).
    func scoreTableRow(for qso: Qso) -> ScoreTableRow {
        let time = formatTime(qso.t)
        let cols: [String]
        switch Settings.simContest {
        case .cwt, .sst, .fieldDay:
            cols = [time, qso.call, qso.exch1, qso.exch2, qso.err, padLeft(qso.trueWpm, 3)]
        case .naQp:
            cols = [time, qso.call, qso.exch1, qso.exch2, qso.pfx, qso.err, padLeft(qso.trueWpm, 3)]
        case .wpx:
            cols = [time, qso.call, String(format: "%03d", qso.rst), String(format: "%4d", qso.nr), qso.err, padLeft(qso.trueWpm, 3)]
        case .hst:
            cols = [time, qso.call, String(format: "%03d", qso.rst),
                    String(format: Settings.runMode == .hst ? "%04d" : "%4d", qso.nr),
                    qso.pfx, qso.err, padLeft(qso.trueWpm, 3)]
        case .cqww:
            cols = [time, qso.call, String(format: "%03d", qso.rst), String(format: "%02d", Int(qso.exch2) ?? 0), qso.err, padLeft(qso.trueWpm, 3)]
        case .arrlDx, .allJa, .acag, .iaruHf:
            cols = [time, qso.call, String(format: "%03d", qso.rst), qso.exch2, qso.err, padLeft(qso.trueWpm, 3)]
        case .arrlSS:
            cols = [time, qso.call, String(format: "%4d", qso.nr), qso.prec,
                    String(format: "%02d", qso.check), qso.sect, qso.err, padLeft(qso.trueWpm, 3)]
        }
        return ScoreTableRow(columns: cols)
    }

    /// After error checking, push the updated row back to the UI
    /// (original ScoreTableUpdateCheck).
    private func refreshLastRow() {
        guard let qso = qsoList.last else { return }
        SimEngine.shared.uiHooks.onScoreTableUpdate?(qsoList.count - 1, scoreTableRow(for: qso))
    }

    private func formatTime(_ t: Double) -> String {
        // t is seconds-of-day/86400
        let totalSeconds = Int(t * 86400)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Delphi `format('%3s', [s])` — left-pad to n characters.
    private func padLeft(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }

    // MARK: - status bar

    public func updateSbar() {
        var s = ""
        if !sbarErrorMsg.isEmpty {
            if !s.isEmpty { s += " -- " }
            s += sbarErrorMsg
        } else if !sbarStationInfo.isEmpty {
            if !s.isEmpty { s += " -- " }
            s += sbarStationInfo
        }
        if !sbarDebugMsg.isEmpty {
            // Note: '%s' in String(format:) expects a C string pointer, not a
            // Swift String — passing a Swift String crashed with SIGSEGV in
            // release builds. Pad manually instead (cross-platform safe).
            let left = s.padding(toLength: 45, withPad: " ", startingAt: 0)
            let right = sbarDebugMsg.padding(toLength: 40, withPad: " ", startingAt: 0)
            s = "  \(left) >> \(right)"
        }
        SimEngine.shared.uiHooks.onStatusBar?(s, !sbarErrorMsg.isEmpty)
    }

    public func displayError(_ exchError: String, isError: Bool) {
        if sbarErrorMsg == exchError && sbarErrorColor == isError { return }
        sbarErrorMsg = exchError
        sbarErrorColor = isError
        updateSbar()
    }

    public func sbarUpdateStationInfo(_ callsign: String) {
        let s = callsign.isEmpty ? "" : (Contest.shared?.getStationInfo(callsign) ?? "")
        sbarStationInfo = s.replacingOccurrences(of: "&", with: "&&")
        updateSbar()
    }

    public func sbarUpdateDebugMsg(_ msg: String) {
        if sbarDebugMsg == msg { return }
        if msg.isEmpty {
            sbarDebugMsg = ""
        } else {
            sbarDebugMsg = String((msg + "; " + sbarDebugMsg).prefix(40))
        }
        updateSbar()
    }

    public func setExchangeSummaryText(_ text: String) {
        if exchangeSummaryText == text { return }
        exchangeSummaryText = text
        updateExchangeSummaryLabel()
    }

    public func updateExchangeSummaryLabel() {
        if exchangeSummaryText.isEmpty || !Settings.showExchangeSummary {
            SimEngine.shared.uiHooks.onExchangeLabel?(
                exchange2Settings[Settings.activeContest.exchType2]?.caption ?? "Exch")
        } else {
            SimEngine.shared.uiHooks.onExchangeLabel?(exchangeSummaryText)
        }
    }

    public func clear() {
        qsoList = []
        rawMultList = []
        verifiedMultList = []
        rawPoints = 0
        verifiedPoints = 0
        callSent = false
        nrSent = false
        sbarDebugMsg = ""
        sbarStationInfo = ""
        exchangeSummaryText = ""
        sbarErrorMsg = ""
        sbarErrorColor = false
    }
}

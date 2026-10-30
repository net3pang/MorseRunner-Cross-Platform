// Port of ArrlSS.pas — the ARRL Sweepstakes contest.
//
// Full exchange: [nr|#] <precedence> <check> <section>. The received
// exchange is parsed incrementally by SSExchParser as the user types.

import Foundation

/// One Sweepstakes call-history record (Delphi `TSweepstakesCallRec`).
final class SweepstakesCallRec {
    var call = ""
    var section = ""    // ARRL/RAC section (e.g. OR)
    var check = 0       // 2-digit year first licensed
    var userText = ""

    var displayString: String {
        String(format: " - CK %02d", check) + ", Sect \(section)"
    }
}

/// ARRL Sweepstakes contest (port of `TSweepstakes`).
final class Sweepstakes: Contest {
    private var callList: [SweepstakesCallRec] = []
    private let exchValidator = SSExchParser()
    private var sections2Idx: [String: Int] = [:]

    override init() {
        super.init()
        for (i, s) in ArrlSections.sectionsTbl.enumerated() {
            sections2Idx[s] = i
        }
    }

    override func loadCallHistory(_ userCallsign: String) -> Bool {
        if !callList.isEmpty { return true }
        callList = []

        guard let text = DataFiles.loadString("SSCW.txt") else { return false }
        let lexer = SSLexer()
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let fields = line.components(separatedBy: ",")
            if fields.count > 3 {
                if fields[0] == "!!Order!!" { continue }
                let rec = SweepstakesCallRec()
                rec.call = fields[0].uppercased()
                rec.section = fields[1].uppercased()
                guard let check = Int(fields[3]) else { continue }
                rec.check = check
                rec.userText = fields.count >= 5 ? fields[4] : ""
                if rec.call.isEmpty { continue }
                if !lexer.isValidCall(rec.call) { continue }
                if rec.section.isEmpty { continue }
                callList.append(rec)
            }
        }
        callList.sort { $0.call < $1.call }
        return true
    }

    /// Sent-exchange syntax: [nr|#] <Precedence> <Check> <Section>.
    /// Returns Exch1 = '[nr|#] <prec>', Exch2 = '<check> <section>'.
    override func validateMyExchange(_ exchange: String, tokens: inout [String]) -> String? {
        let regex = try! NSRegularExpression(
            pattern: " *(?<exch1>(?<nr>[0-9]+|#)? *(?<prec>[QABUMS])) +(?<chk>[0-9]{2}) +(?<sect>[A-Z]{2,3}) *")
        let range = NSRange(exchange.startIndex..., in: exchange)
        guard let match = regex.firstMatch(in: exchange, range: range) else {
            return "Invalid exchange: '\(exchange)' - expecting \(Settings.activeContest.msg)."
        }
        func group(_ name: String) -> String {
            guard let r = match.range(withName: name) as NSRange?,
                  r.location != NSNotFound,
                  let swiftRange = Range(r, in: exchange) else { return "" }
            return String(exchange[swiftRange])
        }
        let exch1 = group("exch1")
        let exch2 = "\(group("chk")) \(group("sect"))"
        tokens = [exch1, exch2]
        return nil
    }

    override func pickStation() -> Int {
        Int.random(in: 0..<callList.count)
    }

    override func dropStation(_ id: Int) {
        assert(id < callList.count)
        callList.remove(at: id)
    }

    override func getCall(_ id: Int) -> String {
        callList[id].call
    }

    func findCallRec(_ call: String) -> SweepstakesCallRec? {
        var lo = 0, hi = callList.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if callList[mid].call < call {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo < callList.count && callList[lo].call == call {
            return callList[lo]
        }
        return nil
    }

    override func getExchange(_ id: Int, into station: DxStation) {
        // Mark KD0EE: ~50% A, 20% B, 20% U; Jim K6OK: 37% A, 19% B, 36% U;
        // average used here: 43% A, 19% B, 28% U, 10% Q/M/S.
        let precedences = ["A", "B", "U", "Q", "M", "S"]
        let r = Float.random(in: 0..<1)
        if r < 0.43 {
            station.prec = precedences[0]
        } else if r < 0.62 {
            station.prec = precedences[1]
        } else if r < 0.90 {
            station.prec = precedences[2]
        } else {
            station.prec = precedences[3 + Int.random(in: 0..<3)]
        }

        station.nr = getRandomSerialNR()
        station.chk = callList[id].check
        station.sect = callList[id].section
        station.userText = callList[id].userText

        // Exch1: <Number> <Precedence> (e.g. 123 A)
        station.exch1 = "\(station.nr) \(station.prec)"
        // Exch2: <Check> <Section> (e.g. 72 OR)
        station.exch2 = String(format: "%02d", station.chk) + " \(station.sect)"
    }

    override func sendMsg(_ stn: Station, _ aMsg: StationMessage) {
        switch aMsg {
        case .cq:
            sendText(stn, "CQ SS <my>")
        case .longCQ:
            sendText(stn, "CQ CQ SS <my> <my> SS")  // QrmStation only
        default:
            super.sendMsg(stn, aMsg)
        }
    }

    override func onWipeBoxes() {
        super.onWipeBoxes()
        exchValidator.onWipeBoxes()
    }

    /// Parse the exchange on each keystroke; return the summary for the
    /// caption above the exchange field.
    override func onExchangeEdit(call: String, exch1: String, exch2: String) -> (summary: String, error: String) {
        if Settings.showExchangeSummary {
            let result = exchValidator.validateEnteredExchange(call, exch1, exch2)
            return (exchValidator.exchSummary, result.error)
        }
        return ("", "")
    }

    override func onExchangeEditComplete() {
        if exchValidator.call.isEmpty {
            super.onExchangeEditComplete()
        } else if exchValidator.call != me.hisCall {
            Log.shared.callSent = false
        }
    }

    /// Apply a callsign correction parsed from the exchange field.
    override func setHisCall(_ call: String) {
        let correctedCallsign = exchValidator.call
        if correctedCallsign.isEmpty {
            super.setHisCall(call)
        } else {
            if correctedCallsign != me.hisCall && !me.updateCallInMessage(correctedCallsign) {
                me.hisCall = correctedCallsign
                Log.shared.callSent = true
            } else if correctedCallsign == me.hisCall && !Log.shared.callSent {
                Log.shared.callSent = true
            }
        }
    }

    override func checkEnteredCallLength(_ call: String, _ error: inout String) -> Bool {
        error = ""
        if exchValidator.call.isEmpty {
            return super.checkEnteredCallLength(call, &error)
        }
        return true
    }

    override func validateEnteredExchange(call: String, exch1: String, exch2: String) -> String? {
        let result = exchValidator.validateEnteredExchange(call, exch1, exch2)
        return result.error.isEmpty ? nil : result.error
    }

    /// Specialized exchange saving from the validator's parsed state.
    override func saveEnteredExchToQso(_ qso: Qso, _ exch1: String, _ exch2: String) {
        qso.nr = exchValidator.nr
        qso.prec = exchValidator.precedence
        qso.check = Int(exchValidator.check) ?? 0
        qso.sect = exchValidator.section

        if qso.prec.isEmpty { qso.prec = "?" }
        if qso.sect.isEmpty { qso.sect = "?" }

        if !exchValidator.call.isEmpty {
            qso.call = exchValidator.call
        }

        qso.exch1 = "\(qso.nr) \(qso.prec)"
        qso.exch2 = String(format: "%02d", qso.check) + " \(qso.sect)"
    }

    override func getStationInfo(_ callsign: String) -> String {
        if let rec = findCallRec(callsign), !rec.userText.isEmpty {
            return Dxcc.shared.displayPrefix(for: callsign) + " - " + rec.userText
        }
        return ""
    }

    /// 2 points per QSO; multiplier = ARRL/RAC section.
    override func extractMultiplier(_ qso: Qso) -> String {
        qso.points = 2
        return qso.sect
    }

    /// '<Check> <Section>' autofill, occasionally corrupted (10%) so the
    /// user has to correct the copied string.
    func getCheckSection(_ callsign: String, threshold: Float = 0) -> String {
        guard let rec = findCallRec(callsign) else { return "" }
        var check = rec.check
        if Float.random(in: 0..<1) < threshold {
            if Int.random(in: 0..<2) == 0 {
                check = (check + 1) % 100
            } else {
                check = ((check - 1) + 100) % 100
            }
        }
        var section = rec.section
        if Float.random(in: 0..<1) < threshold {
            section = getAlternateSection(section)
        }
        return String(format: "%02d", check) + " \(section)"
    }

    private func getAlternateSection(_ section: String) -> String {
        guard let index = sections2Idx[section] else { return section }
        let last = ArrlSections.sectionsTbl.count - 1
        if (Float.random(in: 0..<1) < 0.5 && index > 0) || index == last {
            return ArrlSections.sectionsTbl[index - 1]
        }
        return ArrlSections.sectionsTbl[index + 1]
    }
}

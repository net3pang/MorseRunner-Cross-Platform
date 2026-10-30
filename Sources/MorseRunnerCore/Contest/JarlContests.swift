// Port of ALLJA.pas / ACAG.pas — the JARL ALL JA and ACAG contests.
// The two contests share the same structure: RST + <location><power> exchange,
// multiplier = location code with the trailing power letter stripped.

import Foundation

/// One JARL call-history record (Delphi `TAllJaCallRec`/`TAcagCallRec`).
final class JarlCallRec {
    var call = ""
    var number = ""     // <pref|city|gun|ku><power>
    var userText = ""

    var displayString: String {
        " - NR \(number)"
    }
}

/// JARL ALL JA (port of `TALLJA`).
class ALLJA: Contest {
    fileprivate var callList: [JarlCallRec] = []

    override init() {
        super.init()
    }

    override func loadCallHistory(_ userCallsign: String) -> Bool {
        if !callList.isEmpty { return true }
        callList = []
        guard let text = DataFiles.loadString("JARL_ALLJA.TXT") else { return false }
        parse(text)
        return true
    }

    fileprivate func parse(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("!!Order!!") || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.components(separatedBy: ",")
            if fields.count > 1 {
                let rec = JarlCallRec()
                rec.call = fields[0].uppercased()
                rec.number = fields[1].uppercased()
                if fields.count >= 3 {
                    rec.userText = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if rec.call.isEmpty || rec.number.isEmpty { continue }
                callList.append(rec)
            }
        }
        callList.sort { $0.call < $1.call }
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

    func findCallRec(_ call: String) -> JarlCallRec? {
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
        station.exch1 = "599"
        station.exch2 = callList[id].number
    }

    override func getStationInfo(_ callsign: String) -> String {
        guard let rec = findCallRec(callsign), !rec.userText.isEmpty else { return "" }
        return Dxcc.shared.displayPrefix(for: callsign) + " - " + rec.userText
    }

    /// Multiplier = location code with the trailing power letter (L/M/H/P)
    /// stripped; 1 point per QSO.
    override func extractMultiplier(_ qso: Qso) -> String {
        let s = qso.exch2
        let p = s.last
        if let p, "LMHP".contains(p) {
            qso.points = 1
            return String(s.dropLast())
        }
        qso.points = 1
        return s
    }
}

/// JARL ACAG (port of `TACAG`).
final class ACAG: ALLJA {
    override func loadCallHistory(_ userCallsign: String) -> Bool {
        if !callList.isEmpty { return true }
        callList = []
        guard let text = DataFiles.loadString("JARL_ACAG.TXT") else { return false }
        parse(text)
        return true
    }
}

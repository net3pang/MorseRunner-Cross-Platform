// Port of CWOPS.pas — the CWops CWT contest (minimal contest template).

import Foundation

/// One CWOPS call-history record (Delphi `TCWOPSRec`).
final class CwoRec {
    var call = ""        // station callsign
    var exch1 = ""       // operator name
    var exch2 = ""       // number/state/province/country prefix
    var userText = ""    // station location string

    /// Operator is a CWops member iff the exchange is numeric.
    var isCwoMember: Bool { Settings.isNum(exch2) }
}

/// CWops CWT contest (port of `TCWOPS`).
final class CWOPS: Contest {
    private var list: [CwoRec] = []

    override init() {
        super.init()
    }

    override func loadCallHistory(_ userCallsign: String) -> Bool {
        // reload only if empty
        if !list.isEmpty { return true }
        list = []

        guard let text = DataFiles.loadString("CWOPS.LIST") else { return false }
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("!!Order!!") || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.components(separatedBy: ",")
            if fields.count >= 3 {
                let rec = CwoRec()
                rec.call = fields[0].uppercased()
                rec.exch1 = fields[1].uppercased()
                rec.exch2 = fields[2].uppercased()
                if fields.count > 3 {
                    rec.userText = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if rec.call.isEmpty || rec.exch1.isEmpty || rec.exch2.isEmpty { continue }
                if rec.exch1.count > 10 || rec.exch2.count > 5 { continue }
                list.append(rec)
            }
        }
        list.sort { $0.call < $1.call }
        return true
    }

    override func pickStation() -> Int {
        Int.random(in: 0..<list.count)
    }

    override func dropStation(_ id: Int) {
        assert(id < list.count)
        list.remove(at: id)
    }

    override func getCall(_ id: Int) -> String {
        list[id].call
    }

    func findCallRec(_ call: String) -> CwoRec? {
        // binary search over the sorted list
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].call < call {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo < list.count && list[lo].call == call {
            return list[lo]
        }
        return nil
    }

    override func getExchange(_ id: Int, into station: DxStation) {
        station.opName = list[id].exch1
        station.exch1 = list[id].exch1
        station.exch2 = list[id].exch2
    }

    override func sendMsg(_ stn: Station, _ aMsg: StationMessage) {
        switch aMsg {
        case .cq:
            sendText(stn, "CQ CWT <my>")
        case .rNR:
            if Float.random(in: 0..<1) < 0.9 {
                sendText(stn, "<#>")
            } else {
                sendText(stn, "R <#>")
            }
        case .rNR2:
            if Float.random(in: 0..<1) < 0.9 {
                sendText(stn, "<#> <#>")
            } else {
                sendText(stn, "R <#> <#>")
            }
        case .longCQ:
            sendText(stn, "CQ CQ CWT <my> <my>")  // QrmStation only
        default:
            super.sendMsg(stn, aMsg)
        }
    }

    /// Status-bar info from the CWOPS history. Members show their QTH;
    /// non-members in US/CA show only continent/entity (no state hints).
    override func getStationInfo(_ callsign: String) -> String {
        var userText = ""
        if let rec = findCallRec(callsign) {
            userText = rec.userText
            if let dxrec = Dxcc.shared.findRec(callsign) {
                if userText.isEmpty || (!rec.isCwoMember
                    && (dxrec.entity == "United States of America" || dxrec.entity == "Canada")) {
                    userText = dxrec.continent + "/" + dxrec.entity
                }
            }
            if !userText.isEmpty {
                return Dxcc.shared.displayPrefix(for: callsign) + " - " + userText
            }
        }
        return ""
    }

    /// Unique callsigns worked = multiplier.
    override func extractMultiplier(_ qso: Qso) -> String {
        qso.points = 1
        return qso.call
    }
}

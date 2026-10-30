// Port of CWSST.pas — the K1USN Slow Speed Test contest (Farnsworth).

import Foundation

/// One K1USN SST call-history record (Delphi `TCWSSTRec`).
final class CWSSTRec {
    var call = ""
    var exch1 = ""      // operator name
    var exch2 = ""      // number/state/province/DX
    var userText = ""
}

/// K1USN Slow Speed Test (port of `TCWSST`).
final class CWSST: Contest {
    private var list: [CWSSTRec] = []

    override init() {
        super.init()
        setFarnsworthEnabled(true)
    }

    override func loadCallHistory(_ userCallsign: String) -> Bool {
        if !list.isEmpty { return true }
        list = []

        guard let text = DataFiles.loadString("K1USNSST.txt") else { return false }
        // the Delphi original sorts the raw lines first
        var lines = text.components(separatedBy: .newlines)
        lines.sort()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("!!Order!!") || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.components(separatedBy: ",")
            if fields.count >= 3 {
                let rec = CWSSTRec()
                rec.call = fields[0].uppercased()
                rec.exch1 = fields[1].uppercased()
                rec.exch2 = fields[2].uppercased()
                if fields.count > 3 {
                    rec.userText = fields[3]
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

    func findCallRec(_ call: String) -> CWSSTRec? {
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
            sendText(stn, "CQ SST <my>")  // sent by MyStation
        case .nrQm:
            // sent by calling station (DxStation)
            if stn.myCall == me.myCall {
                sendText(stn, "NR?")
            } else {
                switch Int(floor(stn.r1 * 4)) {
                case 0, 1: sendText(stn, "NR?")
                case 2: sendText(stn, "NAME?")
                default: sendText(stn, "ST?")
                }
            }
        case .tu:
            sendText(stn, "TU <my>")  // sent by MyStation
        case .rNR, .rNR2:
            // exchange msg sent by remote station in response to my exchange
            var prefix = ""
            if Float.random(in: 0..<1) < 0.10 { prefix = "R " }
            if Float.random(in: 0..<1) < 0.20 { prefix += "<greeting> " }
            if aMsg == .rNR {
                sendText(stn, prefix + "<#>")
            } else {
                sendText(stn, prefix + "<#> <#>")
            }
        case .longCQ:
            sendText(stn, "CQ CQ SST <my> <my>")  // QrmStation only
        default:
            super.sendMsg(stn, aMsg)
        }
    }

    override func sendText(_ stn: Station, _ aMsg: String) {
        // the <greeting> token is followed by a space to allow an empty greeting
        if let range = aMsg.range(of: "<greeting> ") {
            var msg = aMsg
            msg.replaceSubrange(range, with: greetingAsText(stn))
            super.sendText(stn, msg)
        } else {
            super.sendText(stn, aMsg)
        }
    }

    /// Random casual conversation string, cached per station ('GM <name> ',
    /// 'GA ...', 'GE ...', or empty 10% of the time).
    func greetingAsText(_ stn: Station) -> String {
        if stn.msgTemp == "undef" {
            let r = Int.random(in: 0..<10)
            let name = Contest.shared?.me.exch1 ?? ""
            switch r {
            case 0...2: stn.msgTemp = "GM \(name) "   // 30%
            case 3...5: stn.msgTemp = "GA \(name) "   // 30%
            case 6...8: stn.msgTemp = "GE \(name) "   // 30%
            default: stn.msgTemp = ""                  // 10%
            }
        }
        return stn.msgTemp
    }

    /// Status-bar info; hide state hints for stations in the user's entity.
    override func getStationInfo(_ callsign: String) -> String {
        guard let rec = findCallRec(callsign) else { return "" }
        var userText = rec.userText
        if userText.isEmpty, let dxrec = Dxcc.shared.findRec(callsign),
           dxrec.entity != me.myEntity {
            userText = dxrec.continent + "/" + dxrec.entity
        }
        if !userText.isEmpty {
            return Dxcc.shared.displayPrefix(for: callsign) + " - " + userText
        }
        return ""
    }

    /// 1 point per QSO; multiplier is state/province, or country for DX.
    override func extractMultiplier(_ qso: Qso) -> String {
        qso.points = 1
        var result = qso.exch2
        if qso.trueExch2 == "DX", let dxrec = Dxcc.shared.findRec(qso.call) {
            result = dxrec.entity
        }
        return result
    }
}

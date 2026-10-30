// Port of NaQp.pas — the NCJ NAQP contest.
//
// NA stations send name + state/province; non-NA stations send name only.
// The exchange type depends on whether each station is local to the contest.

import Foundation

/// One NAQP call-history record (Delphi `TNaQpCallRec`).
final class NaQpCallRec {
    var call = ""
    var name = ""
    var state = ""
    var userText = ""

    var displayString: String {
        " - \(name) \(state)"
    }
}

/// NCJ NAQP contest (port of `TNcjNaQp`).
final class NcjNaQp: DualExchangeContest {
    private var callList: [NaQpCallRec] = []
    private var isCallLocalLastCall = ""
    private var isCallLocalLastResult = false

    init() {
        super.init(
            local1: .opName, local2: .naQpExch2,        // NA station exchange
            dx1: .opName, dx2: .naQpNonNaExch2)         // non-NA station exchange
    }

    override func loadCallHistory(_ userCallsign: String) -> Bool {
        callList = []
        isCallLocalLastCall = ""
        isCallLocalLastResult = false

        guard let text = DataFiles.loadString("NAQPCW.txt") else { return false }
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("!!Order!!") || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.components(separatedBy: ",")
            if fields.count > 2 {
                let rec = NaQpCallRec()
                rec.call = fields[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                rec.name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                rec.state = fields[2].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if fields.count >= 4 {
                    rec.userText = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if rec.call.isEmpty || rec.name.isEmpty { continue }
                if rec.name.count > 12 { continue }
                // ignore empty State; handled in pickStation()
                callList.append(rec)
            }
        }
        callList.sort { $0.call < $1.call }
        return true
    }

    /// Determine whether the user's station is within the NAQP region
    /// (NA continent or Hawaii).
    override func onSetMyCall(_ userCallsign: String) -> Bool {
        if let dxcc = Dxcc.shared.findRec(userCallsign) {
            homeCallIsLocal = dxcc.continent == "NA" || dxcc.entity == "Hawaii"
        } else {
            NSLog("NAQP: '\(userCallsign)' is not recognized as a valid DXCC callsign.")
            // best-guess US/VE determination for the error case
            homeCallIsLocal = userCallsign.hasPrefix("A") || userCallsign.hasPrefix("K")
                || userCallsign.hasPrefix("N") || userCallsign.hasPrefix("W")
                || userCallsign.hasPrefix("VE") || userCallsign.hasPrefix("XE")
            return false
        }
        return super.onSetMyCall(userCallsign)
    }

    override func getExchangeTypes(kind: StationKind, requestedMsgType: RequestedMsgType,
                                   stationCallsign: String, remoteCallsign: String) -> ExchTypes {
        // the exchange type being sent is determined by the sender's location
        if requestedMsgType == .recvMsg && !remoteCallsign.isEmpty {
            return isCallLocalToContest(remoteCallsign) ? localTypes : dxTypes
        }
        return isCallLocalToContest(stationCallsign) ? localTypes : dxTypes
    }

    /// Randomly pick the next station, filtering records deferred from
    /// LoadCallHistory (DXCC validation; non-NA callers skip other non-NA
    /// stations). Rejected records are dropped from the list.
    override func pickStation() -> Int {
        let homeCallIsDX = !homeCallIsLocal
        var result = Int.random(in: 0..<callList.count)
        while callList.count > 1 {
            let rec = callList[result]

            // keep stations that have a valid DXCC entry
            var keep = Dxcc.shared.findRec(rec.call) != nil
            if keep && rec.state.isEmpty {
                // no State: consider whether the call is within the NAQP region
                if let dxcc = Dxcc.shared.findRec(rec.call),
                   dxcc.continent == "NA" || dxcc.entity == "Hawaii" {
                    // use the dxcc prefix if it is simple regex-free text
                    keep = !dxcc.prefixReg.contains("()|,[]*+-")
                    if keep {
                        rec.state = dxcc.prefixReg
                    }
                }
            }

            // non-NA home stations only work NA stations
            if keep && homeCallIsDX && !isCallLocalToContest(rec.call) {
                keep = false
            }

            if keep {
                break
            }

            // drop this station and try again
            dropStation(result)
            result = Int.random(in: 0..<callList.count)
        }
        return result
    }

    override func dropStation(_ id: Int) {
        assert(id < callList.count)
        callList.remove(at: id)
    }

    override func getCall(_ id: Int) -> String {
        callList[id].call
    }

    func findCallRec(_ call: String) -> NaQpCallRec? {
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
        station.exch1 = callList[id].name
        station.opName = station.exch1
        station.exch2 = callList[id].state
        station.userText = callList[id].userText
    }

    override func getStationInfo(_ callsign: String) -> String {
        var userText = ""
        var dxEntity = ""
        if let rec = findCallRec(callsign) {
            userText = rec.userText
            // outside the NA contest region: include continent/entity
            if rec.state.isEmpty, let dxrec = Dxcc.shared.findRec(callsign) {
                dxEntity = dxrec.continent + "/" + dxrec.entity
            }
        }
        if !userText.isEmpty || !dxEntity.isEmpty {
            var result = Dxcc.shared.displayPrefix(for: callsign)
            if !userText.isEmpty { result += " - " + userText }
            if !dxEntity.isEmpty { result += " - " + dxEntity }
            return result
        }
        return ""
    }

    /// NA stations use State/Prov as the multiplier; non-NA stations none.
    override func extractMultiplier(_ qso: Qso) -> String {
        qso.points = 1
        return isCallLocalToContest(qso.call) ? qso.exch2 : ""
    }

    /// Whether the station is within the NAQP contest region (memoized).
    func isCallLocalToContest(_ callsign: String) -> Bool {
        if isCallLocalLastCall != callsign {
            isCallLocalLastCall = callsign
            isCallLocalLastResult = false
            if let dxrec = Dxcc.shared.findRec(callsign) {
                isCallLocalLastResult = dxrec.continent == "NA" || dxrec.entity == "Hawaii"
            }
        }
        return isCallLocalLastResult
    }
}

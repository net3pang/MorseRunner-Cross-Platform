// Port of ArrlDx.pas — the ARRL DX contest.
//
// W/VE stations send RST + state/province; DX stations send RST + power.
// The exchange types flip based on whether each station is local (xor logic
// in DualExchangeContest).

import Foundation

/// One ARRL DX call-history record (Delphi `TArrlDxCallRec`).
final class ArrlDxCallRec {
    var call = ""
    var state = ""      // State/Province (US/Canada)
    var power = ""      // Power (DX stations)
    var userText = ""   // club name

    var displayString: String {
        var r = " - \(state)\(power)"
        if !userText.isEmpty {
            r += " " + userText
        }
        return r
    }
}

/// ARRL DX contest (port of `TArrlDx`).
final class ArrlDx: DualExchangeContest {
    private var callList: [ArrlDxCallRec] = []

    init() {
        super.init(
            local1: .rst, local2: .stateProv,   // US/CA station exchange
            dx1: .rst, dx2: .power)             // DX station exchange
    }

    /// For US/CA calls, load DX callsigns; for DX calls, load US/CA calls.
    override func loadCallHistory(_ userCallsign: String) -> Bool {
        guard let text = DataFiles.loadString("ARRLDXCW_USDX.txt") else { return false }
        callList = []

        var callInx = -1
        var stateInx = -1
        var powerInx = -1
        var userTextInx = -1

        func getValue(_ columnInx: Int, from fields: [String]) -> String {
            if columnInx >= 0 && columnInx < fields.count {
                return fields[columnInx].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }

        let lines = text.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            var fields = line.components(separatedBy: ",")
            // skip empty or comment lines
            if fields.isEmpty { continue }
            if fields[0].trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }

            if fields[0] == "!!Order!!" {
                // !!Order!!,Call,Name,State,Power,UserText,
                fields.removeFirst()
                callInx = fields.firstIndex(of: "Call") ?? -1
                stateInx = fields.firstIndex(of: "State") ?? -1
                powerInx = fields.firstIndex(of: "Power") ?? -1
                userTextInx = fields.firstIndex(of: "UserText") ?? -1
                if callInx == -1 {
                    NSLog("Invalid call history file: missing required 'Call' field, line \(i + 1)")
                    return false
                }
                continue
            }

            let rec = ArrlDxCallRec()
            rec.call = getValue(callInx, from: fields).uppercased()
            rec.state = getValue(stateInx, from: fields).uppercased()
            rec.power = getValue(powerInx, from: fields).uppercased()
            rec.userText = getValue(userTextInx, from: fields)

            if rec.call.isEmpty { continue }

            // W/VE stations work only DX stations (non-empty Power);
            // DX stations work only W/VE stations (non-empty State)
            if (homeCallIsLocal && !rec.power.isEmpty)
                || (!homeCallIsLocal && !rec.state.isEmpty) {
                callList.append(rec)
            }
        }
        callList.sort { $0.call < $1.call }
        return true
    }

    /// Determine whether the user's station is a W/VE station.
    override func onSetMyCall(_ userCallsign: String) -> Bool {
        if let dxcc = Dxcc.shared.findRec(userCallsign) {
            homeCallIsLocal = dxcc.entity == "United States of America" || dxcc.entity == "Canada"
        } else {
            NSLog("ARRL DX: '\(userCallsign)' is not recognized as a valid DXCC callsign.")
            // best-guess US/VE determination for the error case
            homeCallIsLocal = userCallsign.hasPrefix("A") || userCallsign.hasPrefix("K")
                || userCallsign.hasPrefix("N") || userCallsign.hasPrefix("W")
                || userCallsign.hasPrefix("VE")
            return false
        }
        return super.onSetMyCall(userCallsign)
    }

    override func pickStation() -> Int {
        var result = Int.random(in: 0..<callList.count)
        while callList.count > 1 {
            // keep stations that have a valid DXCC entry
            if Dxcc.shared.findRec(callList[result].call) != nil {
                break
            }
            dropStation(result)
            result = Int.random(in: 0..<callList.count)
        }
        return result
    }

    override func dropStation(_ id: Int) {
        callList.remove(at: id)
    }

    override func getCall(_ id: Int) -> String {
        callList[id].call
    }

    func findCallRec(_ call: String) -> ArrlDxCallRec? {
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
        station.exch2 = callList[id].state + callList[id].power
        station.userText = callList[id].userText
    }

    /// Status-bar info: user text + continent/entity for DX callers.
    override func getStationInfo(_ callsign: String) -> String {
        var userText = ""
        var dxEntity = ""
        if let rec = findCallRec(callsign) {
            userText = rec.userText
            // DX callers get their continent/entity
            if homeCallIsLocal, let dxcc = Dxcc.shared.findRec(callsign) {
                dxEntity = dxcc.continent + "/" + dxcc.entity
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

    /// 3 points per QSO; multiplier = DXCC entity (W/VE) or state/province (DX).
    override func extractMultiplier(_ qso: Qso) -> String {
        qso.points = 3
        if homeCallIsLocal {
            if let dxrec = Dxcc.shared.findRec(qso.call) {
                return dxrec.entity
            }
            return ""
        }
        return qso.exch2
    }
}

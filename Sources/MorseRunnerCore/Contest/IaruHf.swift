// Port of IaruHf.pas — the IARU HF contest.

import Foundation

/// One IARU HF call-history record (Delphi `TIaruHfCallRec`).
final class IaruHfCallRec {
    var call = ""
    var sect = ""       // IARU Society or ITU Zone
    var userText = ""

    var displayString: String {
        var r = " - \(sect)"
        if !userText.isEmpty {
            r += " " + userText
        }
        return r
    }
}

/// IARU HF contest (port of `TIaruHf`).
final class IaruHf: Contest {
    private var callList: [IaruHfCallRec] = []
    private var myContinent = ""

    override init() {
        super.init()
    }

    override func loadCallHistory(_ userCallsign: String) -> Bool {
        guard let text = DataFiles.loadString("IARU_HF.txt") else { return false }
        callList = []

        // the Delphi original checks the user's DXCC record per line; check once
        let userHasDxcc = Dxcc.shared.findRec(userCallsign) != nil

        var dupList: [String] = []
        var callInx = -1
        var sectInx = -1
        var userTextInx = -1

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let fields = line.components(separatedBy: ",")
            if fields.isEmpty { continue }
            let first = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if first.hasPrefix("#") || fields.count < 3 { continue }
            if first == "!!Order!!" {
                // !!Order!!,Call,Sect,UserText,
                callInx = fields.firstIndex(of: "Call") ?? -1
                sectInx = fields.firstIndex(of: "Sect") ?? -1
                userTextInx = fields.firstIndex(of: "UserText") ?? -1
                assert(callInx != -1 && sectInx != -1 && userTextInx != -1)
                continue
            }
            guard callInx != -1, callInx < fields.count, sectInx < fields.count else { continue }

            let rec = IaruHfCallRec()
            // Trim removes unexpected spaces in some records
            rec.call = fields[callInx].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            rec.sect = fields[sectInx].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            rec.userText = fields.count > userTextInx
                ? fields[userTextInx].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            if rec.call.isEmpty || rec.sect.isEmpty { continue }

            // eliminate duplicates
            if dupList.contains(rec.call) { continue }
            dupList.append(rec.call)

            // only include calls with a usable DXCC lookup of the user's call
            if userHasDxcc {
                callList.append(rec)
            }
        }

        // final sort in case of multiple file sections
        callList.sort { $0.call < $1.call }
        return true
    }

    /// Determine the user's continent; validate the call against DXCC.
    override func onSetMyCall(_ userCallsign: String) -> Bool {
        var ok = true
        if let dxcc = Dxcc.shared.findRec(userCallsign) {
            myContinent = dxcc.continent
        } else {
            NSLog("IARU HF: '\(userCallsign)' is not recognized as a valid DXCC callsign.")
            ok = false
        }
        return super.onSetMyCall(userCallsign) && ok
    }

    override func pickStation() -> Int {
        Int.random(in: 0..<callList.count)
    }

    override func dropStation(_ id: Int) {
        callList.remove(at: id)
    }

    override func getCall(_ id: Int) -> String {
        callList[id].call
    }

    func findCallRec(_ call: String) -> IaruHfCallRec? {
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
        station.exch2 = callList[id].sect
        station.userText = callList[id].userText
    }

    /// Status-bar info: user text + continent/entity ('USA' for US).
    override func getStationInfo(_ callsign: String) -> String {
        var userText = ""
        if let rec = findCallRec(callsign) {
            userText = rec.userText
        }
        var dxEntity = ""
        if let dxcc = Dxcc.shared.findRec(callsign) {
            let entity = dxcc.entity == "United States of America" ? "USA" : dxcc.entity
            dxEntity = dxcc.continent + "/" + entity
        }
        if !userText.isEmpty || !dxEntity.isEmpty {
            var result = Dxcc.shared.displayPrefix(for: callsign)
            if !userText.isEmpty { result += " - " + userText }
            if !dxEntity.isEmpty { result += " - " + dxEntity }
            return result
        }
        return ""
    }

    /// 1 point (same zone or HQ society), 3 (different zone, same continent),
    /// 5 (different continent). Multiplier = society or ITU zone.
    override func extractMultiplier(_ qso: Qso) -> String {
        if qso.exch2 == (Contest.shared?.me.exch2 ?? "") || !Settings.isNum(qso.exch2) {
            qso.points = 1
        } else if let dxrec = Dxcc.shared.findRec(qso.call) {
            qso.points = dxrec.continent == myContinent ? 3 : 5
        } else {
            qso.points = 1
        }
        return qso.exch2
    }
}

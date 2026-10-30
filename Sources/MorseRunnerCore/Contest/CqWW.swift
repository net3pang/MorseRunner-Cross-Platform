// Port of CqWW.pas — the CQ WW contest.

import Foundation

/// One CQWW call-history record (Delphi `TCqWwCallRec`).
final class CqWwCallRec {
    var call = ""
    var cqZone = ""
    var userText = ""

    var displayString: String {
        " - CQ-Zone \(cqZone)"
    }
}

/// CQ WW contest (port of `TCqWw`).
final class CqWW: Contest {
    private var callList: [CqWwCallRec] = []
    private var myContinent = ""
    private var myEntity = ""

    override init() {
        super.init()
    }

    override func loadCallHistory(_ userCallsign: String) -> Bool {
        // reload only if empty
        if !callList.isEmpty { return true }
        callList = []

        guard let text = DataFiles.loadString("CQWWCW.txt") else { return false }
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("!!Order!!") || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.components(separatedBy: ",")
            if fields.count > 2 {
                let rec = CqWwCallRec()
                rec.call = fields[0].uppercased()
                rec.cqZone = fields[1].uppercased()
                if fields.count >= 3 {
                    rec.userText = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if rec.call.isEmpty || rec.cqZone.isEmpty { continue }
                if !Settings.isNum(rec.cqZone) { continue }
                callList.append(rec)
            }
        }
        callList.sort { $0.call < $1.call }

        // load MyContinent and MyEntity — used by ExtractMultiplier
        if let dxrec = Dxcc.shared.findRec(userCallsign) {
            myContinent = dxrec.continent
            myEntity = dxrec.entity
        }
        return true
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

    func findCallRec(_ call: String) -> CqWwCallRec? {
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
        station.exch1 = "599"                       // RST
        station.exch2 = getExch2(id)                // CQ zone
        station.nr = Int(station.exch2) ?? 0
    }

    /// RST (always 599).
    func getExch1(_ id: Int) -> String { "599" }

    /// CQ zone with an occasional leading zero for zones 1-8.
    func getExch2(_ id: Int) -> String {
        var result = callList[id].cqZone
        if (Int(result) ?? 99) < 9 && Float.random(in: 0..<1) < 0.05 {
            result = "0" + result
        }
        return result
    }

    func getZone(_ id: Int) -> String { callList[id].cqZone }

    /// Status-bar info: user text and DXCC entity/continent.
    override func getStationInfo(_ callsign: String) -> String {
        var userText = ""
        var dxEntity = ""
        if let rec = findCallRec(callsign) {
            userText = rec.userText
            if let dxrec = Dxcc.shared.findRec(callsign) {
                dxEntity = dxrec.continent + "/" + dxrec.entity
            }
        }
        if !userText.isEmpty || !dxEntity.isEmpty {
            var result = Dxcc.shared.displayPrefix(for: callsign)
            if !userText.isEmpty {
                result += " - " + userText
            }
            if !dxEntity.isEmpty {
                result += " - " + dxEntity
            }
            return result
        }
        return ""
    }

    /// Multiplier = CQ zone + country. Points by continent/entity rules.
    override func extractMultiplier(_ qso: Qso) -> String {
        // first multiplier is the CQ zone
        var result = String(format: "ZN-%d", qso.nr)

        // maritime-mobile stations count only as a zone multiplier
        if qso.call.hasSuffix("/MM") {
            qso.points = 0
            return result
        }

        // second multiplier is unique country names
        if let dxrec = Dxcc.shared.findRec(qso.call) {
            // Alaska and Hawaii are part of the 50 US states
            if dxrec.entity == "Alaska" || dxrec.entity == "Hawaii" {
                result += ";United States of America"
            } else {
                result += ";" + dxrec.entity
            }

            // QSO points based on the location of the station worked
            if dxrec.continent != myContinent {
                qso.points = 3
            } else if dxrec.entity == myEntity {
                qso.points = 0
            } else if dxrec.continent == "NA" {
                qso.points = 2
            } else {
                qso.points = 1
            }
        }
        return result
    }
}

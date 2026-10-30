// Port of ArrlFd.pas — the ARRL Field Day contest.
//
// The call history is loaded in two passes: pass 1 keeps club stations
// (class A/C/F) and defers home/portable stations (B/D/E) with club names;
// pass 2 adds one pending call per unclaimed club (keeping 25% of home
// stations and all portable stations) — a realistic club-quota simulation.

import Foundation

/// One Field Day call-history record (Delphi `TFdCallRec`).
final class FdCallRec {
    var call = ""
    var stnClass = ""   // station classification (e.g. 3A)
    var section = ""    // ARRL/RAC section (e.g. OR)
    var userText = ""   // club name

    /// Leading digits of the class = transmitter count (e.g. '3A' -> 3).
    var txCnt: Int {
        var count = 0
        for ch in stnClass where ch.isNumber {
            count += 1
        }
        return Int(stnClass.prefix(count)) ?? 0
    }

    var displayString: String {
        " - \(stnClass) \(section) \(userText)"
    }
}

/// ARRL Field Day contest (port of `TArrlFieldDay`).
final class ArrlFieldDay: Contest {
    private var fdCallList: [FdCallRec] = []
    private var pendingStations: [String: [FdCallRec]] = [:]
    private var clubNames: [String: FdCallRec] = [:]

    override init() {
        super.init()
    }

    /// Two-pass load of FDGOTA.TXT (port of `TArrlFieldDay.LoadCallHistory`).
    override func loadCallHistory(_ userCallsign: String) -> Bool {
        if !fdCallList.isEmpty { return true }
        fdCallList = []
        pendingStations = [:]
        clubNames = [:]

        guard let text = DataFiles.loadString("FDGOTA.TXT") else { return false }
        let lines = text.components(separatedBy: .newlines)

        func parse(_ fields: [String]) -> FdCallRec? {
            if fields.count <= 2 { return nil }
            let rec = FdCallRec()
            rec.call = fields[0].uppercased()
            rec.stnClass = fields[1].uppercased()
            rec.section = fields[2].uppercased()
            rec.userText = fields.count >= 4
                ? fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            if rec.call.isEmpty || rec.stnClass.isEmpty || rec.section.isEmpty {
                return nil
            }
            return rec
        }

        // Pass 1: club stations (class A/C/F) and deferred home/portable
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("!!Order!!") || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.components(separatedBy: ",")
            guard let rec = parse(fields) else { continue }

            let lastChar = rec.stnClass.suffix(1)
            let homeStn = lastChar == "D" || lastChar == "E"
            let portableStn = lastChar == "B"

            if homeStn || portableStn {
                if rec.userText.isEmpty {
                    // home/portable stations without a club name: keep 25%
                    if Float.random(in: 0..<1) < 0.25 {
                        fdCallList.append(rec)
                    }
                } else {
                    // retain this call and club name to see if it is part of a club
                    pendingStations[rec.userText, default: []].append(rec)
                }
            } else {
                // club station (A, C, or F)
                if !rec.userText.isEmpty {
                    // have we seen this club name before?
                    if let existing = clubNames[rec.userText] {
                        // keep the station with the higher transmitter count
                        if rec.txCnt > existing.txCnt {
                            fdCallList.removeAll { $0 === existing }
                            fdCallList.append(rec)
                            clubNames[rec.userText] = rec
                        }
                        continue
                    }
                    clubNames[rec.userText] = rec
                }
                fdCallList.append(rec)
            }
        }

        // Pass 2: add one pending home/portable call per unclaimed club,
        // keeping all portable stations and 25% of home stations.
        for (club, pending) in pendingStations {
            // skip clubs with an associated station from pass 1
            if clubNames[club] != nil { continue }

            guard let rec = pickPendingCall(pending) else { continue }
            if rec.stnClass.hasSuffix("B") || Float.random(in: 0..<1) < 0.25 {
                fdCallList.append(rec)
                clubNames[rec.userText] = rec
            }
        }

        fdCallList.sort { $0.call < $1.call }
        return true
    }

    /// Pick among the stations with the highest transmitter count
    /// (Delphi `TPendingClubCalls.PickPendingCallIdx`).
    private func pickPendingCall(_ list: [FdCallRec]) -> FdCallRec? {
        guard !list.isEmpty else { return nil }
        let sorted = list.sorted { $0.txCnt > $1.txCnt }
        let topTx = sorted[0].txCnt
        // EndIdx: index after the last station with the same top TxCnt
        var endIdx = sorted.count
        for (i, rec) in sorted.enumerated() where rec.txCnt != topTx {
            endIdx = i
            break
        }
        if endIdx > 1 {
            return sorted[Int.random(in: 0..<endIdx)]
        }
        return sorted[0]
    }

    override func pickStation() -> Int {
        Int.random(in: 0..<fdCallList.count)
    }

    override func dropStation(_ id: Int) {
        assert(id < fdCallList.count)
        fdCallList.remove(at: id)
    }

    override func getCall(_ id: Int) -> String {
        fdCallList[id].call
    }

    func findCallRec(_ call: String) -> FdCallRec? {
        var lo = 0, hi = fdCallList.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if fdCallList[mid].call < call {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo < fdCallList.count && fdCallList[lo].call == call {
            return fdCallList[lo]
        }
        return nil
    }

    override func getExchange(_ id: Int, into station: DxStation) {
        station.exch1 = fdCallList[id].stnClass
        station.exch2 = fdCallList[id].section
        station.userText = fdCallList[id].userText
    }

    override func sendMsg(_ stn: Station, _ aMsg: StationMessage) {
        switch aMsg {
        case .cq:
            sendText(stn, "CQ FD <my>")
        case .nrQm:
            if stn.myCall == me.myCall {
                sendText(stn, "NR?")
            } else {
                switch Int(floor(stn.r1 * 5)) {
                case 0, 1: sendText(stn, "NR?")
                case 2: sendText(stn, "SECT?")
                case 3: sendText(stn, "CLASS?")
                default: sendText(stn, "CL?")
                }
            }
        case .longCQ:
            sendText(stn, "CQ CQ FD <my> <my> FD")  // QrmStation only
        default:
            super.sendMsg(stn, aMsg)
        }
    }

    /// Status-bar info: club name; DX entity for Section='DX'.
    override func getStationInfo(_ callsign: String) -> String {
        guard let rec = findCallRec(callsign) else { return "" }
        var userText = rec.userText
        var dxEntity = ""
        if rec.section == "DX", let dxrec = Dxcc.shared.findRec(callsign) {
            dxEntity = dxrec.continent + "/" + dxrec.entity
        }
        if !userText.isEmpty || !dxEntity.isEmpty {
            var result = Dxcc.shared.displayPrefix(for: callsign)
            if !userText.isEmpty { result += " - " + userText }
            if !dxEntity.isEmpty { result += " - " + dxEntity }
            return result
        }
        return ""
    }

    /// Field Day has no explicit multiplier; 2 points per QSO.
    override func extractMultiplier(_ qso: Qso) -> String {
        qso.points = 2
        return "1"
    }
}

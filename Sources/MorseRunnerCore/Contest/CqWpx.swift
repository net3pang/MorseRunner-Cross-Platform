// Port of CqWpx.pas — the CQ WPX contest.
//
// Uses the global Master.dta callsign list; serial numbers follow the F6FVY
// 2023 WPX submission distribution for mid/end-of-contest modes.

import Foundation

/// CQ WPX contest (port of `TCqWpx`).
final class CqWpx: Contest {
    private var callLst = CallList()
    private let serialNRGen = SerialNRGen()
    private var prevSerialNRType: SerialNRType? = nil
    private var prevRangeStr = ""

    override init() {
        super.init()
        initSerialNRGen()
    }

    /// Distribution of the largest serial numbers sent by single-ops,
    /// from the 2023 CQ WPX public logs (F6FVY, Issue #269).
    static let sampleTbl: [SerNRSampleBin] = [
        SerNRSampleBin(b:    0, c: 344),  // 0-9
        SerNRSampleBin(b:   10, c: 188),  // 10-19
        SerNRSampleBin(b:   20, c: 178),  // 20-29
        SerNRSampleBin(b:   30, c: 164),  // 30-39
        SerNRSampleBin(b:   40, c: 156),  // 40-49
        SerNRSampleBin(b:   50, c: 179),  // 50-59
        SerNRSampleBin(b:   60, c: 149),  // 60-69
        SerNRSampleBin(b:   70, c: 126),  // 70-79
        SerNRSampleBin(b:   80, c: 118),  // 80-89
        SerNRSampleBin(b:   90, c: 124),  // 90-100
        SerNRSampleBin(b:  100, c: 957),  // 100-200
        SerNRSampleBin(b:  200, c: 628),  // 200-300
        SerNRSampleBin(b:  300, c: 368),  // 300-400
        SerNRSampleBin(b:  400, c: 257),  // 400-500
        SerNRSampleBin(b:  500, c: 239),  // 500-600
        SerNRSampleBin(b:  600, c: 150),  // 600-700
        SerNRSampleBin(b:  700, c: 129),  // 700-800
        SerNRSampleBin(b:  800, c: 100),  // 800-900
        SerNRSampleBin(b:  900, c:  65),  // 900-1000
        SerNRSampleBin(b: 1000, c:  79),  // 1000-1100
        SerNRSampleBin(b: 1100, c:  59),  // 1100-1200
        SerNRSampleBin(b: 1200, c:  47),  // 1200-1300
        SerNRSampleBin(b: 1300, c:  44),  // 1300-1400
        SerNRSampleBin(b: 1400, c:  26),  // 1400-1500
        SerNRSampleBin(b: 1500, c:  28),  // 1500-1600
        SerNRSampleBin(b: 1600, c:  36),  // 1600-1700
        SerNRSampleBin(b: 1700, c:  23),  // 1700-1800
        SerNRSampleBin(b: 1800, c:  25),  // 1800-1900
        SerNRSampleBin(b: 1900, c:  23),  // 1900-2000
        SerNRSampleBin(b: 2000, c:  17),  // 2000-2100
        SerNRSampleBin(b: 2100, c:  24),  // 2100-2200
        SerNRSampleBin(b: 2200, c:  16),  // 2200-2300
        SerNRSampleBin(b: 2300, c:  15),  // 2300-2400
        SerNRSampleBin(b: 2400, c:   7),  // 2400-2500
        SerNRSampleBin(b: 2500, c:  11),  // 2500-2600
        SerNRSampleBin(b: 2600, c:   6),  // 2600-2700
        SerNRSampleBin(b: 2700, c:  11),  // 2700-2800
        SerNRSampleBin(b: 2800, c:   4),  // 2800-2900
        SerNRSampleBin(b: 2900, c:   5),  // 2900-3000
        SerNRSampleBin(b: 3000, c:   6),  // 3000-3100
        SerNRSampleBin(b: 3100, c:   1),  // 3100-3200
        SerNRSampleBin(b: 3200, c:   4),  // 3200-3300
        SerNRSampleBin(b: 3300, c:   6),  // 3300-3400
        SerNRSampleBin(b: 3400, c:   3),  // 3400-3500
        SerNRSampleBin(b: 3500, c:   1),  // 3500-3600
        SerNRSampleBin(b: 3600, c:   2),  // 3600-3700
        SerNRSampleBin(b: 3700, c:   3),  // 3700-3800
        SerNRSampleBin(b: 3800, c:   0),  // 3800-3900
        SerNRSampleBin(b: 3900, c:   1),  // 3900-4000
        SerNRSampleBin(b: 4000, c:   2),  // 4000-4100
        SerNRSampleBin(b: 4100, c:   0),  // 4100-4200
        SerNRSampleBin(b: 4200, c:   0),  // 4200-4300
        SerNRSampleBin(b: 4300, c:   0),  // 4300-4400
        SerNRSampleBin(b: 4400, c:   0),  // 4400-4500
        SerNRSampleBin(b: 4500, c:   0),  // 4500-4600
        SerNRSampleBin(b: 4600, c:   1),  // 4600-4700
        SerNRSampleBin(b: 4700, c:   0),  // 4700-4800
        SerNRSampleBin(b: 4800, c:   0),  // 4800-4900
        SerNRSampleBin(b: 4900, c:   0),  // 4900-5000
        SerNRSampleBin(b: 5000, c: 0xFFFF),
    ]

    /// Rebuild the serial number generator tables for the current menu pick.
    func initSerialNRGen() {
        guard let range = Settings.serialNRSettings[Settings.serialNR] else { return }
        if Settings.serialNR == prevSerialNRType && range.rangeStr == prevRangeStr {
            return
        }
        switch Settings.serialNR {
        case .startContest, .customRange:
            serialNRGen.addRange(range)
        case .midContest, .endContest:
            serialNRGen.addDistribution(range, sampleTbl: CqWpx.sampleTbl)
        }
        prevSerialNRType = Settings.serialNR
        prevRangeStr = range.rangeStr
    }

    /// Refresh the generator before the contest starts; then reload the
    /// user's own serial number (mid/end-of-contest modes get a realistic
    /// random starting NR).
    override func onContestPrepareToStart(_ userCallsign: String, sentExchange: String) -> Bool {
        initSerialNRGen()
        // Me.NR is set from the user's exchange field (SetMyExch2); no random
        // override here (original calls MainForm.SetMySerialNR -> SetMyExch2).
        return super.onContestPrepareToStart(userCallsign, sentExchange: sentExchange)
    }

    override func serialNrModeChanged() {
        assert(Settings.runMode != .stop)
        initSerialNRGen()
    }

    override func loadCallHistory(_ userCallsign: String) -> Bool {
        if !callLst.isEmpty { return true }
        callLst.loadCallList()
        return true
    }

    /// CQ WPX uses the global calls list; index is unused.
    override func pickStation() -> Int {
        -1
    }

    override func dropStation(_ id: Int) {
        // already deleted by getCall (HST consumes calls)
    }

    override func getCall(_ id: Int) -> String {
        callLst.pickCall()
    }

    override func getExchange(_ id: Int, into station: DxStation) {
        station.exch1 = "599"
        station.nr = getNR(station)
        station.exch2 = String(station.nr)
    }

    /// Serial number for a DX station: elapsed-time based for HST /
    /// start-of-contest; WPX distribution for mid/end-of-contest.
    private func getNR(_ station: DxStation) -> Int {
        if Settings.runMode == .hst || Settings.serialNR == .startContest {
            return station.oper.getNR()
        }
        return getRandomSerialNR()
    }

    override func getRandomSerialNR() -> Int {
        serialNRGen.getNR()
    }

    override func getStationInfo(_ callsign: String) -> String {
        if let dxrec = Dxcc.shared.findRec(callsign) {
            return "\(Dxcc.shared.displayPrefix(for: callsign)) - \(dxrec.continent)/\(dxrec.entity)"
        }
        return ""
    }

    /// Multiplier = unique WPX prefixes worked.
    override func extractMultiplier(_ qso: Qso) -> String {
        qso.points = 1
        return qso.pfx
    }
}

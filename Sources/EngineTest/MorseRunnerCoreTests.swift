// Engine-level end-to-end verification for the cross-platform MorseRunner.
// Runs the simulation headlessly: contest creation, station spawning,
// a complete QSO flow, the scoring path, and run/stop/restart regressions.
//
// Run with: swift test

import Foundation
import XCTest
@testable import MorseRunnerCore

nonisolated(unsafe) var failures = 0

func check(_ cond: Bool, _ name: String) {
    if cond {
        print("PASS: \(name)")
    } else {
        failures += 1
        print("FAIL: \(name)")
    }
}

final class MorseRunnerCoreTests: XCTestCase {
    func testAllChecks() throws {
        failures = 0

        // ---- 1. DXCC lookup
        let dxcc = Dxcc.shared
        let ve3 = dxcc.findRec("VE3NEA")
        check(ve3?.entity == "Canada", "DXCC: VE3NEA -> Canada (got \(ve3?.entity ?? "nil"))")
        check(dxcc.findRec("W7SST")?.entity == "United States of America", "DXCC: W7SST -> USA")

        // ---- 2. Keyer envelope
        let keyer = Keyer()
        keyer.setWpm(25)
        keyer.morseMsg = keyer.encode("CQ TEST VE3NEA")
        let env = keyer.getEnvelope()
        check(env.count % 512 == 0, "Keyer: envelope padded to whole blocks (\(env.count) samples)")
        check(env.contains(1), "Keyer: envelope has tone segments")
        let envLen = keyer.trueEnvelopeLen
        check(envLen > 0 && envLen <= env.count, "Keyer: trueEnvelopeLen \(envLen) within buffer")

        // ---- 3. Contest factory: all 12 contests construct
        for (i, def) in contestDefinitions.enumerated() {
            let contest = ContestFactory.create(SimContest(rawValue: i)!)
            check(type(of: contest) != Contest.self, "Factory: \(def.name) -> \(type(of: contest))")
        }

        // ---- 4. CWOPS history load
        let cwo = CWOPS()
        Settings.call = "VE3NEA"
        Settings.simContest = .cwt
        Contest.shared = cwo
        let loaded = cwo.loadCallHistory("VE3NEA")
        check(loaded, "CWOPS: loadCallHistory")
        check(cwo.findCallRec("2E0DCW") != nil, "CWOPS: known call found (2E0DCW)")
        guard loaded else {
            print("ABORT: CWOPS.LIST could not be loaded; cannot run simulation tests")
            return
        }

        // ---- 5. Simulated run: stations spawn
        Settings.runMode = .pileup
        Settings.activity = 2
        Settings.duration = 30
        cwo.initContest()
        cwo.me.myCall = "VE3NEA"
        _ = cwo.onSetMyCall("VE3NEA")
        cwo.me.sendMsg(.cq)
        var spawnCount = 0
        for _ in 0..<3000 {
            _ = cwo.getAudio()
            if cwo.stations.count > 0 {
                spawnCount = cwo.stations.count
                break
            }
            // mimic an active operator: call CQ again as soon as idle
            if cwo.me.state == .listening && cwo.me.envelope == nil {
                cwo.me.sendMsg(.cq)
            }
        }
        check(spawnCount > 0, "Run: DX stations spawn after CQ (\(spawnCount) stations)")

        // let the first caller start sending, then verify the DX operator asks for a QSO
        guard let dx = cwo.stations.items.first as? DxStation else {
            print("FAIL: no DxStation in collection")
            return
        }
        check(dx.oper.state == .needQso || dx.oper.state == .needPrevEnd,
              "Run: DX operator in \(dx.oper.state) after spawn")

        // ---- 6. Complete a QSO through the engine
        cwo.me.hisCall = dx.myCall
        cwo.stations.findBestMatches(dx.myCall)
        // the DX station is copying while the user sends
        dx.state = .copying
        cwo.me.msg = .hisCall
        cwo.me.state = .listening
        for stn in cwo.stations.items {
            stn.processEvent(.meFinished)
        }
        check(dx.oper.state == .needNr || dx.oper.state == .needCallNr,
              "QSO: operator advanced to \(dx.oper.state) after my call")

        // user sends the exchange (0.9 chance to advance; MorePatience otherwise)
        dx.state = .copying
        cwo.me.msg = .nr
        cwo.me.state = .listening
        for stn in cwo.stations.items {
            stn.processEvent(.meFinished)
        }
        check(dx.oper.state == .needEnd || dx.oper.state == .needNr,
              "QSO: operator in \(dx.oper.state) after my exchange")

        // user sends TU (completes the QSO from either state)
        dx.state = .copying
        cwo.me.msg = .tu
        cwo.me.state = .listening
        for stn in cwo.stations.items {
            stn.processEvent(.meFinished)
        }
        check(dx.oper.state == .done, "QSO: operator done after TU")

        // ---- 7. Log the QSO
        Settings.simContest = .cwt
        let qso = Qso()
        qso.call = dx.myCall
        qso.exch1 = dx.exch1
        qso.exch2 = dx.exch2
        qso.trueCall = dx.myCall
        qso.trueExch1 = dx.exch1
        qso.trueExch2 = dx.exch2
        let mult = cwo.extractMultiplier(qso)
        check(mult == qso.call, "CWOPS: multiplier = unique call")
        check(qso.points == 1, "CWOPS: 1 point per QSO")

        // ---- 8. NrAsText exchange formatting (WPX: RST + serial with cut numbers)
        Settings.simContest = .wpx
        let stn = DxStation()
        stn.myCall = "K7OK"
        stn.rst = 599
        stn.nr = 123
        stn.sentExchTypes = ExchTypes(exch1: .rst, exch2: .serialNr)
        Settings.runMode = .pileup
        let txt = stn.nrAsText()
        // DX stations render 599 as 5NN (or rarely ENN) cut numbers
        check(txt.contains("NN") && txt.contains("123"),
              "NrAsText: RST rendered as cut numbers (\(txt))")

        // ---- 9. Serial NR generator distribution
        let gen = SerialNRGen()
        var range = SerialNumberSettings(key: "t", rangeStr: "50-500", minVal: 50, maxVal: 500, minDigits: 2, maxDigits: 3)
        gen.addDistribution(range, sampleTbl: CqWpx.sampleTbl)
        var nrs: Set<Int> = []
        for _ in 0..<1000 {
            nrs.insert(gen.getNR())
        }
        check(nrs.count > 100, "SerialNRGen: mid-contest distribution produces variety (\(nrs.count) distinct)")

        // ---- 10. SS exchange parser (full exchange is entered in one string)
        let ss = SSExchParser()
        let r = ss.validateEnteredExchange("K7OK", "", "123 A 72 OR")
        check(r.valid, "SSExchParser: '123 A 72 OR' parses")
        check(ss.nr == 123 && ss.precedence == "A" && ss.check == "72" && ss.section == "OR",
              "SSExchParser: fields (\(ss.nr) \(ss.precedence) \(ss.check) \(ss.section))")
        let r2 = ss.validateEnteredExchange("K7OK", "", "99 ZZ")
        check(!r2.valid, "SSExchParser: invalid section rejected")

        // ---- 11. Audio backend abstraction (no platform frameworks needed).
        // The engine depends only on the AudioBackend protocol; verify the
        // silent backend delivers blocks synchronously.
        let audio: AudioBackend = SilentAudioBackend()
        var blocksGenerated = 0
        audio.start {
            blocksGenerated += 1
            // one block of 600 Hz tone to exercise the DSP path end to end
            var block = SampleArray(repeating: 0, count: 512)
            for i in 0..<512 {
                block[i] = 2000 * sin(2 * Float.pi * 600 * Float(i) / 11025)
            }
            return block
        }
        for _ in 0..<30 {
            (audio as? SilentAudioBackend)?.advanceForTesting()
        }
        audio.stop()
        check(blocksGenerated >= 10, "SilentAudioBackend: engine generated \(blocksGenerated) blocks")

        // ---- 12. Regression: stop then restart the run (user-reported bug)
        let sim = SimController.shared
        Settings.call = "VE3NEA"
        Settings.simContest = .cwt
        Settings.activity = 1
        Settings.duration = 30
        Settings.qsb = false; Settings.qrm = false; Settings.qrn = false
        sim.setContest(.cwt)
        sim.run(.pileup)
        check(sim.runMode == .pileup, "Restart: run starts")
        sim.stop()
        check(sim.runMode == .stop, "Restart: stop returns to stopped")
        sim.run(.pileup)
        check(sim.runMode == .pileup, "Restart: run restarts after stop")
        sim.stop()
        check(sim.runMode == .stop, "Restart: second stop works")

        XCTAssertEqual(failures, 0, "\(failures) test(s) failed")
    }

    /// Editing the call after Enter must update the portion that has not yet
    /// been transmitted, while preserving the already-sent prefix.
    func testCallsignCanBeCorrectedWhileSending() {
        Settings.simContest = .wpx
        Settings.runMode = .pileup
        let contest = CqWpx()
        Contest.shared = contest
        contest.initContest()
        contest.me.myCall = "VE3NEA"
        _ = contest.onSetMyCall("VE3NEA")

        let sim = SimController.shared
        sim.enteredCall = "K1ABC"
        contest.me.sendText("<his>")
        XCTAssertEqual(contest.me.hisCall, "K1ABC")

        // Let the first audio block leave the station, then correct only the
        // suffix.  The shared prefix remains identical, so the in-flight
        // envelope can be replaced safely.
        _ = contest.me.getBlock()
        sim.enteredCall = "K1ABD"
        XCTAssertEqual(contest.me.hisCall, "K1ABD")
        sim.wipeBoxes()
    }

    /// Keyer: character spacing inside a single callsign must be the
    /// standard 1U intra-character / 3U inter-character (Delphi comment:
    /// "' ': AddOff(2,0) // 3U inter-char spacing (2U + prior 1U)").
    func testKeyerCharacterSpacing() {
        let keyer = Keyer()
        keyer.setWpm(25, 25)
        keyer.morseMsg = keyer.encode("P29SX")
        let env = keyer.getEnvelope()
        let rate = Double(AudioConstants.defaultRate)
        let samplesInUnit = Double(bankersRound(60.0 / 48.0 * Double(rate) / 25.0))

        var runs: [(start: Int, end: Int)] = []
        var inRun = false
        var start = 0
        for i in 0..<env.count {
            let on = env[i] > 0.5
            if on && !inRun { inRun = true; start = i }
            if !on && inRun { inRun = false; runs.append((start, i)) }
        }
        if inRun { runs.append((start, env.count)) }

        var maxGap = 0.0
        var maxIntraGap = 0.0
        for idx in 1..<runs.count {
            let gapU = Double(runs[idx].start - runs[idx-1].end) / samplesInUnit
            maxGap = max(maxGap, gapU)
            if gapU < 2.0 {
                maxIntraGap = max(maxIntraGap, gapU)
            }
        }
        print("KEYER max gap = \(String(format: "%.2f", maxGap))U, max intra = \(String(format: "%.2f", maxIntraGap))U")
        XCTAssertLessThan(maxIntraGap, 1.6, "Intra-character gaps should be ~1U")
        XCTAssertLessThan(maxGap, 3.1, "No stretched gaps inside the callsign")
    }

    /// My station's sent exchange types and cut-number formatting: after
    /// setting my call, RST exchanges must be sent as short codes (5NN).
    func testMyStationCutNumbers() {
        let contest = CqWpx()
        Contest.shared = contest
        Settings.call = "VE3NEA"
        Settings.simContest = .wpx
        Settings.runMode = .pileup
        Settings.activity = 0
        contest.initContest()
        contest.me.myCall = "VE3NEA"
        let ok = contest.onSetMyCall("VE3NEA")
        XCTAssertEqual(contest.me.sentExchTypes.exch1.rawValue, 0, "my RST exchange type should be .rst")
        contest.me.nr = 123
        contest.me.rst = 599
        let txt = contest.me.nrAsText()
        print("MYSTN: onSetMyCall=\(ok) nrAsText=\(txt)")
        XCTAssertTrue(txt.contains("5NN"), "my exchange should use cut numbers (5NN), got \(txt)")
        XCTAssertFalse(txt.contains("599"), "my exchange must not contain long 599, got \(txt)")
    }

    /// GUI Enter flow: call -> Enter (fills RST via onAdvance), exchange ->
    /// Enter -> TU + QSO saved. Uses direct getAudio() driving (like the
    /// GUI's audio pump) rather than RunLoop timers, which are unreliable
    /// under XCTest.
    func testEnterFlowSavesQso() {
        Settings.simContest = .wpx
        Settings.call = "VE3NEA"
        Settings.activity = 2
        Settings.duration = 30
        Settings.qsb = false
        Settings.qrm = false
        Settings.qrn = false
        Settings.debugCwDecoder = false
        Settings.runMode = .pileup
        Log.shared.clear()

        let contest = CqWpx()
        Contest.shared = contest
        contest.initContest()
        contest.me.myCall = "VE3NEA"
        _ = contest.onSetMyCall("VE3NEA")

        let sim = SimController.shared
        // simulate the UI onAdvance hook (fills RST=599 and focuses Exch2)
        var advanceCount = 0
        SimEngine.shared.uiHooks.onAdvance = {
            advanceCount += 1
            if sim.enteredExch1.isEmpty && SimEngine.shared.uiHooks.recvExchTypes.exch1 == .rst {
                sim.enteredExch1 = "599"
            }
        }

        // drive the simulation directly; call CQ like a real operator
        contest.me.sendMsg(.cq)
        var dxCall = ""
        var cqCount = 1
        var lastCqBlock = 0
        for blk in 0..<3000 {
            _ = contest.getAudio()
            if dxCall.isEmpty, let dx = contest.stations.items.first as? DxStation {
                dxCall = dx.myCall
            }
            if dxCall.isEmpty && contest.me.state == .listening && contest.me.envelope == nil
                && blk - lastCqBlock > 200 && cqCount < 4 {
                contest.me.sendMsg(.cq)
                cqCount += 1
                lastCqBlock = blk
            }
            if !dxCall.isEmpty && blk > 400 { break }
        }
        XCTAssertFalse(dxCall.isEmpty, "DX station should appear")

        // call -> Enter: sends his call + nr, then advances (fills RST)
        sim.enteredCall = dxCall
        sim.enterKeyPressed()
        // MustAdvance fires at the next envelope end (original behavior), so
        // drive a few blocks before checking the RST auto-fill.
        for _ in 0..<200 { _ = contest.getAudio() }
        XCTAssertEqual(sim.enteredExch1, "599", "RST should be auto-filled by onAdvance")
        XCTAssertTrue(Log.shared.callSent, "Call should be sent")
        XCTAssertTrue(Log.shared.nrSent, "NR should be sent")

        // typing a callsign must not trigger advance/fill (no MustAdvance)
        SimEngine.shared.mustAdvance = false
        sim.enteredCall = "K1ABC"
        let advancesBeforeTyping = advanceCount
        for _ in 0..<200 { _ = contest.getAudio() }
        XCTAssertEqual(advanceCount, advancesBeforeTyping,
                       "typing a call must not trigger the advance/focus jump")
        sim.enteredCall = dxCall

        // exchange -> Enter: sends TU and saves the QSO
        sim.enteredExch2 = "123"
        sim.enterKeyPressed()
        XCTAssertEqual(Log.shared.qsoList.count, 1, "QSO should be logged after exchange Enter")
        // after saving, entry state must be wiped (original WipeBoxes) so the
        // next callsign doesn't re-save with stale RST=599 / NR values
        XCTAssertEqual(sim.enteredCall, "", "call should be wiped after QSO")
        XCTAssertEqual(sim.enteredExch1, "", "RST should be wiped after QSO")
        XCTAssertEqual(sim.enteredExch2, "", "NR should be wiped after QSO")
        XCTAssertFalse(Log.shared.callSent, "callSent should reset after QSO")
        XCTAssertFalse(Log.shared.nrSent, "nrSent should reset after QSO")
        print("ENTFLOW: dxCall=\(dxCall) exch1=\(sim.enteredExch1) qso=\(Log.shared.qsoList.count) callSent=\(Log.shared.callSent)")
    }

    /// Verified score must only count error-free QSOs (err == "   ").
    func testVerifiedScoreOnlyCleanQsos() {
        Log.shared.clear()
        Settings.simContest = .wpx
        Settings.call = "VE3NEA"
        Settings.runMode = .pileup
        let contest = CqWpx()
        Contest.shared = contest
        contest.initContest()
        contest.me.myCall = "VE3NEA"
        _ = contest.onSetMyCall("VE3NEA")

        let clean = Qso()
        clean.call = "K7OK"
        clean.points = 1
        clean.err = "   "
        clean.multStr = "K7"
        let bad = Qso()
        bad.call = "W1AW"
        bad.points = 1
        bad.err = "NR"
        bad.multStr = "W1"
        Log.shared.qsoList = [clean, bad]

        Log.shared.updateStats(verifyResults: true)
        print("VERIFIED: pts=\(Log.shared.verifiedPoints) mults=\(Log.shared.verifiedMultList.count)")
        XCTAssertEqual(Log.shared.verifiedPoints, 1, "Only the clean QSO counts in verified score")
        XCTAssertEqual(Log.shared.verifiedMultList.count, 1, "Only the clean QSO's mult counts")
    }

    /// Settings persistence: my call written to defaults must come back on load.
    /// WPX serial numbers: start at 001 and increment after each saved QSO.
    func testWpxSerialNumberIncrements() {
        Settings.serialNR = .startContest
        Settings.simContest = .wpx
        Settings.call = "VE3NEA"
        Settings.runMode = .pileup
        let contest = CqWpx()
        Contest.shared = contest
        contest.initContest()
        contest.me.myCall = "VE3NEA"
        _ = contest.onSetMyCall("VE3NEA")

        // prepare like SimController.run does
        _ = contest.onContestPrepareToStart("VE3NEA", sentExchange: "5NN #")
        print("WPNR: init me.nr=\(contest.me.nr)")
        XCTAssertEqual(contest.me.nr, 1, "start-of-contest '#' exchange starts at 001")
        contest.me.rst = 599

        // QSO 1: send exchange then save (0 -> T is cut-number formatting)
        let first = contest.me.nrAsText()
        XCTAssertTrue(first.contains("TT1"), "first serial should be 001 (as TT1), got \(first)")
        Log.shared.clear()
        Log.shared.saveQso(call: "K7OK", exch1: "599", exch2: "1")
        print("WPNR: after save1 me.nr=\(contest.me.nr)")

        // QSO 2
        let second = contest.me.nrAsText()
        XCTAssertTrue(second.contains("TT2"), "second serial should be 002 (as TT2), got \(second)")
        Log.shared.saveQso(call: "W1AW", exch1: "599", exch2: "2")
        let third = contest.me.nrAsText()
        XCTAssertTrue(third.contains("TT3"), "third serial should be 003 (as TT3), got \(third)")
        print("WPNR: first=\(first) second=\(second) third=\(third)")
    }

    /// QSO errors must be recomputed and pushed to the UI when the DX
    /// station data arrives (original ScoreTableUpdateCheck).
    func testQsoErrorMarkingRefreshesRow() {
        Settings.simContest = .wpx
        Settings.call = "VE3NEA"
        Settings.runMode = .pileup
        let contest = CqWpx()
        Contest.shared = contest
        contest.initContest()
        contest.me.myCall = "VE3NEA"
        _ = contest.onSetMyCall("VE3NEA")
        Log.shared.clear()

        var updated: (Int, ScoreTableRow)?
        SimEngine.shared.uiHooks.onScoreTableUpdate = { idx, row in
            updated = (idx, row)
        }

        // save a QSO whose call does NOT match the DX station (wrong call)
        let qso = Qso()
        qso.call = "K7OK"
        qso.exch1 = "599"
        qso.exch2 = "1"
        Log.shared.qsoList = [qso]
        Log.shared.checkErr()
        XCTAssertNotNil(updated, "checkErr should refresh the last row")
        if let (idx, row) = updated {
            XCTAssertEqual(idx, 0, "should update row 0")
            let errCol = row.columns.count > 4 ? row.columns[4] : ""
            print("QSOERR: errCol=\(errCol)")
            XCTAssertFalse(errCol.isEmpty || errCol == "   ", "wrong call should be marked, got '\(errCol)'")
        }
    }

    /// End-to-end WPX: two consecutive QSOs through the real entry flow must
    /// send serial 001 then 002 (increment after each saved QSO).
    func testWpxEndToEndSerialIncrement() {
        Settings.simContest = .wpx
        Settings.call = "VE3NEA"
        Settings.serialNR = .startContest
        Settings.activity = 2
        Settings.duration = 30
        Settings.qsb = false
        Settings.qrm = false
        Settings.qrn = false
        Settings.debugCwDecoder = false
        Settings.runMode = .pileup
        Log.shared.clear()

        let contest = CqWpx()
        Contest.shared = contest
        contest.initContest()
        contest.me.myCall = "VE3NEA"
        _ = contest.onSetMyCall("VE3NEA")
        _ = contest.onContestPrepareToStart("VE3NEA", sentExchange: "5NN #")
        contest.me.rst = 599
        contest.me.exch1 = "5NN"

        let sim = SimController.shared
        SimEngine.shared.uiHooks.onAdvance = {
            if sim.enteredExch1.isEmpty && SimEngine.shared.uiHooks.recvExchTypes.exch1 == .rst {
                sim.enteredExch1 = "599"
            }
        }

        func workOneQso(_ dxCall: String, expectedNr: Int) {
            sim.enteredCall = dxCall
            sim.enterKeyPressed()
            for _ in 0..<200 { _ = contest.getAudio() }
            XCTAssertEqual(sim.enteredExch1, "599", "RST auto-filled")
            sim.enteredExch2 = String(expectedNr)
            sim.enterKeyPressed()
            for _ in 0..<100 { _ = contest.getAudio() }
        }

        // QSO 1
        contest.me.sendMsg(.cq)
        var dxCall = ""
        var cqCount = 1
        var lastCqBlock = 0
        for blk in 0..<3000 {
            _ = contest.getAudio()
            if dxCall.isEmpty, let dx = contest.stations.items.first as? DxStation {
                dxCall = dx.myCall
            }
            if dxCall.isEmpty && contest.me.state == .listening && contest.me.envelope == nil
                && blk - lastCqBlock > 200 && cqCount < 4 {
                contest.me.sendMsg(.cq)
                cqCount += 1
                lastCqBlock = blk
            }
            if !dxCall.isEmpty && blk > 400 { break }
        }
        XCTAssertFalse(dxCall.isEmpty, "DX station should appear")
        workOneQso(dxCall, expectedNr: 1)
        XCTAssertEqual(contest.me.nr, 2, "me.nr should increment after QSO1 save")
        let sent1 = contest.me.nrAsText()
        print("WPXE2E: after QSO1 me.nr=\(contest.me.nr) sent=\(sent1)")

        // QSO 2 (new DX station)
        sim.enteredCall = ""
        sim.enteredExch1 = ""
        sim.enteredExch2 = ""
        Log.shared.callSent = false
        Log.shared.nrSent = false
        var dxCall2 = ""
        var lastCq2 = 0
        var cq2Count = 0
        for blk in 0..<3000 {
            _ = contest.getAudio()
            if dxCall2.isEmpty, let dx = contest.stations.items.first as? DxStation {
                dxCall2 = dx.myCall
            }
            if dxCall2.isEmpty && contest.me.state == .listening && contest.me.envelope == nil
                && blk - lastCq2 > 200 && cq2Count < 4 {
                contest.me.sendMsg(.cq)
                cq2Count += 1
                lastCq2 = blk
            }
            if !dxCall2.isEmpty && blk > 200 { break }
        }
        XCTAssertFalse(dxCall2.isEmpty, "second DX station should appear")
        workOneQso(dxCall2, expectedNr: 2)
        XCTAssertEqual(contest.me.nr, 3, "me.nr should increment after QSO2 save")
        let sent2 = contest.me.nrAsText()
        print("WPXE2E: after QSO2 me.nr=\(contest.me.nr) sent=\(sent2)")
        XCTAssertTrue(sent2.contains("TT3") || sent2.contains("003"),
                      "second serial should be 003 (as TT3), got \(sent2)")
    }

    /// CQ WW: my sent exchange must be RST + CQ zone (e.g. "5NN 3"),
    /// not the stale initStation defaults ("3A OR").
    func testCqwwSentExchange() {
        Settings.simContest = .cqww
        Settings.call = "VE3NEA"
        Settings.runMode = .pileup
        let contest = CqWW()
        Contest.shared = contest
        contest.initContest()
        contest.me.myCall = "VE3NEA"
        _ = contest.onSetMyCall("VE3NEA")

        // emulate the UI: user's sent exchange "5NN 3"
        let sim = SimController.shared
        sim.setMyCall("VE3NEA")
        _ = sim.setMyExchange("5NN 3")
        print("CQWW: rst=\(contest.me.rst) exch1=\(contest.me.exch1) exch2=\(contest.me.exch2)")
        XCTAssertEqual(contest.me.rst, 599, "5NN should expand to 599")
        XCTAssertEqual(contest.me.exch1, "5NN", "exch1 should be the literal RST")
        XCTAssertEqual(contest.me.exch2, "3", "exch2 should be the CQ zone")

        let sent = contest.me.nrAsText()
        print("CQWW sent=\(sent)")
        XCTAssertTrue(sent.hasPrefix("5NN"), "CQ WW exchange should start with 5NN, got \(sent)")
        XCTAssertTrue(sent.contains("3"), "CQ WW exchange should contain the zone, got \(sent)")
        XCTAssertFalse(sent.contains("3A"), "must not send the stale 3A OR default")
    }

    /// setContest must apply the loaded call, not overwrite it with the
    /// controller's stale initial value (VE3NEA).
    func testSetContestKeepsLoadedCall() {
        Settings.call = "XX9ZZ"
        let sim = SimController.shared
        sim.setContest(.wpx)
        XCTAssertEqual(Settings.call, "XX9ZZ", "setContest must keep the loaded call")
        sim.stop()
    }

    /// After run() (which re-inits Me), the sent exchange types must be
    /// restored so "5NN #" validates and cut numbers are applied.
    func testRunRestoresExchangeTypes() {
        Settings.simContest = .wpx
        Settings.call = "VE3NEA"
        Settings.serialNR = .startContest
        Settings.activity = 1
        Settings.duration = 30
        Settings.qsb = false
        Settings.qrm = false
        Settings.qrn = false
        Log.shared.clear()
        let sim = SimController.shared
        sim.setContest(.wpx)
        _ = sim.setMyExchange("5NN #")
        sim.run(.pileup)
        defer { sim.stop() }

        let contest = Contest.shared
        XCTAssertNotNil(contest, "contest should exist")
        XCTAssertEqual(contest?.me.sentExchTypes.exch1, .rst, "RST exchange type restored")
        XCTAssertEqual(contest?.me.sentExchTypes.exch2, .serialNr, "serial Nr exchange type restored")
        contest?.me.nr = 1
        contest?.me.rst = 599
        let txt = contest?.me.nrAsText() ?? ""
        print("RUNEX: sent=\(txt)")
        XCTAssertTrue(txt.contains("5NN"), "WPX exchange should use 5NN short code, got \(txt)")
    }

    /// Switching to CQ WW must use that contest's default exchange (5NN 3),
    /// not a stale "5NN #".
    func testCqwwDefaultExchange() {
        Settings.call = "VE3NEA"
        let sim = SimController.shared
        sim.setContest(.cqww)
        print("CQWWDEF: exchangeEdit=\(sim.exchangeEdit)")
        XCTAssertEqual(sim.exchangeEdit, "5NN 24", "CQ WW default exchange should be '5NN 24'")
        var tokens: [String] = []
        let err = Contest.shared?.validateMyExchange("5NN 24", tokens: &tokens)
        XCTAssertNil(err, "5NN 24 should validate for CQ WW")
        sim.stop()
    }

    /// End-of-run: onRunStopped must fire exactly once and the pump returns
    /// silence afterwards (regression for the end-of-run app freeze).
    func testRunExpiryHandledOnce() {
        Settings.simContest = .wpx
        Settings.call = "BH5HIE"
        Settings.runMode = .pileup
        Settings.duration = 1
        Settings.activity = 0
        Settings.qsb = false
        Settings.qrm = false
        Settings.qrn = false
        let contest = CqWpx()
        Contest.shared = contest
        contest.initContest()
        SimEngine.shared.stopHandled = false

        var stoppedCount = 0
        SimEngine.shared.uiHooks.onRunStopped = { stoppedCount += 1 }
        for _ in 0..<6000 {
            _ = contest.getAudio()
            if SimEngine.shared.stopHandled { break }
        }
        XCTAssertTrue(SimEngine.shared.stopHandled, "run should have ended")
        XCTAssertTrue(SimEngine.shared.runExpired, "time-limit expiry should set runExpired")
        XCTAssertEqual(stoppedCount, 1, "onRunStopped should fire exactly once")
        // further blocks must stay silent and not re-fire the handler
        for _ in 0..<100 { _ = contest.getAudio() }
        XCTAssertEqual(stoppedCount, 1, "no repeated onRunStopped after expiry")
        SimEngine.shared.uiHooks.onRunStopped = nil
        print("RUNEXP: handled=\(SimEngine.shared.stopHandled) fires=\(stoppedCount)")
    }

    func testCallPersistence() {
        let original = Settings.call
        Settings.call = "XX9ZZ"
        Settings.saveToDefaults()
        Settings.call = "VE3NEA"
        Settings.loadFromDefaults()
        XCTAssertEqual(Settings.call, "XX9ZZ", "call should persist across load")
        Settings.call = original
        Settings.saveToDefaults()
    }

    func testSingleCallsMode() {
        // Direct getAudio() driving (like the GUI audio pump); RunLoop timers
        // are unreliable under XCTest.
        Settings.simContest = .wpx
        Settings.call = "VE3NEA"
        Settings.activity = 2
        Settings.duration = 30
        Settings.qsb = false
        Settings.qrm = false
        Settings.qrn = false
        Settings.flutter = false
        Settings.lids = false
        Settings.runMode = .single
        Log.shared.clear()

        let contest = CqWpx()
        Contest.shared = contest
        contest.initContest()
        contest.me.myCall = "VE3NEA"
        _ = contest.onSetMyCall("VE3NEA")

        var dxSending = false
        var maxStations = 0
        for blk in 0..<3000 {
            _ = contest.getAudio()
            maxStations = max(maxStations, contest.stations.count)
            for stn in contest.stations.items {
                if let dx = stn as? DxStation, dx.state == .sending && dx.envelope != nil {
                    dxSending = true
                    break
                }
            }
            if dxSending && blk > 600 { break }
        }
        XCTAssertTrue(dxSending, "Single mode DX station should transmit")
        XCTAssertGreaterThan(maxStations, 0, "Single mode should spawn stations")

        // Complete a QSO through the real entry path while the DX is calling.
        let sim = SimController.shared
        if let dx = contest.stations.items.first as? DxStation {
            sim.enteredCall = dx.myCall
            sim.sendMsg(.hisCall)
            sim.enteredExch1 = dx.exch1
            sim.enteredExch2 = dx.exch2
            sim.tuAndSave()
        }
        for _ in 0..<100 { _ = contest.getAudio() }
        print("SINGLE: dxSending=\(dxSending) maxStations=\(maxStations) qsoList=\(Log.shared.qsoList.count)")
        XCTAssertEqual(Log.shared.qsoList.count, 1, "QSO should be logged")
    }

    func testDxStationsTransmitAfterCq() {
        let contest = CqWpx()
        Contest.shared = contest
        Settings.call = "VE3NEA"
        Settings.simContest = .wpx
        Settings.runMode = .pileup
        Settings.activity = 4
        Settings.duration = 60
        Settings.qsb = false
        contest.initContest()
        contest.me.myCall = "VE3NEA"
        _ = contest.onSetMyCall("VE3NEA")

        contest.me.sendMsg(.cq)
        var dxSending = false
        var dxStates: [String] = []
        var sawEnvelope = false
        var lastLog = ""
        var envelopeProgress = -1
        var dxFinished = false
        var cqCount = 1
        var lastCqBlock = 0
        for blk in 0..<4000 {
            _ = contest.getAudio()
            if blk % 200 == 0 {
                lastLog = "blk=\(blk) meState=\(contest.me.state.rawValue) meMsg=\(contest.me.msg.rawValue) activity=\(Settings.activity) noAct=\(Settings.noActivityCnt) stations=\(contest.stations.count) " +
                          contest.stations.items.map { "\($0.state.rawValue)/env=\($0.envelope != nil ? "y" : "n")" }.joined(separator: ",")
            }
            // re-CQ (like a real operator) but leave a window for DX replies:
            // the CQ itself is ~120 blocks, so wait 200 blocks total between
            // CQ starts, otherwise re-CQ interrupts the DX station (meStarted).
            if !dxSending && contest.me.state == .listening && contest.me.envelope == nil
                && blk - lastCqBlock > 200 && cqCount < 8 {
                contest.me.sendMsg(.cq)
                cqCount += 1
                lastCqBlock = blk
            }
            for stn in contest.stations.items {
                if let dx = stn as? DxStation {
                    if dx.state == .sending && dx.envelope != nil {
                        if !dxSending {
                            print("DX-TX first send: msgText='\(dx.msgText)' env=\(dx.envelope?.count ?? -1) wpmS=\(dx.wpmS) sendPos=\(dx.sendPos)")
                        }
                        dxSending = true
                        sawEnvelope = true
                    }
                    if dxSending && dxStates.count < 20 {
                        dxStates.append("\(dx.oper.state.rawValue)/\(dx.state.rawValue)")
                    }
                }
            }
            if dxSending {
                // track envelope drain progress once
                if let dx = contest.stations.items.first as? DxStation, dx.state == .sending {
                    if envelopeProgress == -1 { envelopeProgress = 0 }
                    envelopeProgress = max(envelopeProgress, dx.sendPos)
                }
                if let dx = contest.stations.items.first as? DxStation, dx.state == .listening {
                    if !dxFinished {
                        print("DX-TX finished: maxSendPos=\(envelopeProgress) env=\(dx.envelope?.count ?? -1)")
                        dxFinished = true
                    }
                }
            }
            if dxSending && dxStates.count >= 20 && (envelopeProgress > 0 || dxFinished) {
                break
            }
        }
        print("DX-TX: \(lastLog) dxSending=\(dxSending) states=\(dxStates.prefix(10).joined(separator: ","))")
        XCTAssertTrue(dxSending, "A DX station should start transmitting after the CQ")
    }

    /// DSP chain: after sending CQ, the output must contain a strong 600 Hz
    /// tone (the modulated CW signal), not just broadband noise.
    func testDspChainProducesTone() throws {
        let contest = CqWpx()
        Contest.shared = contest
        Settings.call = "VE3NEA"
        Settings.simContest = .wpx
        Settings.runMode = .pileup
        Settings.activity = 0
        Settings.duration = 30
        contest.initContest()
        contest.me.myCall = "VE3NEA"
        _ = contest.onSetMyCall("VE3NEA")
        contest.me.sendMsg(.cq)

        print("DSP setup: me.amplitude=\(contest.me.amplitude) me.state=\(contest.me.state.rawValue) envMax=\(contest.me.envelope?.max() ?? -1)")
        print("DSP agc: noiseIn=\(contest.agc.noiseInDb)dB noiseOut=\(contest.agc.noiseOutDb)dB beta=\(contest.agc.debugBeta)")

        // collect 2 seconds of audio after the first 6 warm-up blocks
        var samples: SampleArray = []
        var envelopeMaxSeen: Float = 0
        for _ in 0..<300 {
            let blk = contest.getAudio()
            envelopeMaxSeen = max(envelopeMaxSeen, contest.me.envelope?.max() ?? 0)
            if blk.count == 512 && samples.count < 22050 {
                samples.append(contentsOf: blk)
            }
        }
        print("DSP during run: envelopeMaxSeen=\(envelopeMaxSeen)")

        // 600 Hz reference correlation over the collected audio
        let rate = Double(AudioConstants.defaultRate)
        let n = samples.count
        var cosSum = 0.0, sinSum = 0.0, energy = 0.0
        for (i, s) in samples.enumerated() {
            let ph = 2.0 * Double.pi * 600.0 * Double(i) / rate
            cosSum += Double(s) * cos(ph)
            sinSum += Double(s) * sin(ph)
            energy += Double(s) * Double(s)
        }
        let tonePower = (cosSum * cosSum + sinSum * sinSum) / Double(n)
        let ratio = energy > 0 ? tonePower / (energy / Double(n)) : 0
        print("DSP tone ratio=\(ratio) peak=\(samples.map { abs($0) }.max() ?? 0)")
        XCTAssertGreaterThan(ratio, 0.5, "CQ output should be dominated by the 600 Hz tone")
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 1000,
                             "CQ output should have audible level (16-bit scale)")
    }

    /// Isolate the modulator + AGC chain with a constant strong input.
    func testModulatorAgcChain() {
        let contest = CqWpx()
        Contest.shared = contest
        Settings.call = "VE3NEA"
        Settings.simContest = .wpx
        Settings.runMode = .pileup
        contest.initContest()

        var reIm = ReImArrays()
        reIm.setLength(512)
        for i in 0..<512 {
            reIm.re[i] = 300000   // strong constant signal (like a CW element)
            reIm.im[i] = 0
        }
        let mod = contest.modul.modulate(reIm)
        print("MOD: max=\(mod.map { abs($0) }.max() ?? 0) rms=\(sqrt(mod.map { Double($0*$0) }.reduce(0,+) / Double(mod.count)))")
        let out = contest.agc.process(mod)
        print("AGC: max=\(out.map { abs($0) }.max() ?? 0) rms=\(sqrt(out.map { Double($0*$0) }.reduce(0,+) / Double(out.count)))")

        // steady-state: feed several blocks so AGC buffers fill
        var lastMax: Float = 0
        for _ in 0..<20 {
            let o = contest.agc.process(mod)
            lastMax = o.map { abs($0) }.max() ?? 0
        }
        print("AGC steady max=\(lastMax)")
        XCTAssertGreaterThan(lastMax, 5000, "AGC steady-state output should approach 20k for strong input")

        // Measure the receive filter's response to a 600 Hz complex signal.
        let filt = contest.filt
        print("FILT: points=\(filt.points) passes=\(filt.passes) gainDb=\(filt.gainDb) norm=\(filt.debugNorm)")
        var tone = ReImArrays()
        tone.setLength(512)
        let dPhi = Float(AudioConstants.twoPi) * 600.0 / Float(AudioConstants.defaultRate)
        for i in 0..<512 {
            let ph = Float(i) * dPhi
            tone.re[i] = 300000 * cos(ph)
            tone.im[i] = -300000 * sin(ph)
        }
        var maxOut: Float = 0
        for _ in 0..<50 {   // let the filter settle
            let o = filt.filter(tone)
            maxOut = max(maxOut, o.re.map { abs($0) }.max() ?? 0)
            maxOut = max(maxOut, o.im.map { abs($0) }.max() ?? 0)
        }
        print("FILT 600Hz out max=\(maxOut) (in 300000)")
    }
}

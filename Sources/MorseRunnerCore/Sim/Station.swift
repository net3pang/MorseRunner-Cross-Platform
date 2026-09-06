// Port of Station.pas — the base station class of the simulation.
//
// A station owns an audio envelope (the CW it is transmitting), a state
// machine driven by per-block `Tick()`, and the message/reply vocabulary
// shared by every simulated operator.

import Foundation

/// Message classes a station may send during one transmission (Delphi
/// `TStationMessage`). A transmission accumulates a *set* of these.
public enum StationMessage: Int, CaseIterable {
    case none = 0, cq, nr, tu, myCall, hisCall, b4, qm, nil_, garbage,
         rNR, rNR2, deMyCall1, deMyCall2, deMyCallNr1, deMyCallNr2,
         myCallNr1, myCallNr2, myCall2, nrQm, longCQ, qrl, qrl2, qsy, agn
}

/// Set of message classes (Delphi `TStationMessages`).
public struct StationMessages: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    nonisolated(unsafe) public static let none = StationMessages(rawValue: 0)
    nonisolated(unsafe) public static let cq = StationMessages(rawValue: 1 << StationMessage.cq.rawValue)
    nonisolated(unsafe) public static let nr = StationMessages(rawValue: 1 << StationMessage.nr.rawValue)
    nonisolated(unsafe) public static let tu = StationMessages(rawValue: 1 << StationMessage.tu.rawValue)
    nonisolated(unsafe) public static let myCall = StationMessages(rawValue: 1 << StationMessage.myCall.rawValue)
    nonisolated(unsafe) public static let hisCall = StationMessages(rawValue: 1 << StationMessage.hisCall.rawValue)
    nonisolated(unsafe) public static let b4 = StationMessages(rawValue: 1 << StationMessage.b4.rawValue)
    nonisolated(unsafe) public static let qm = StationMessages(rawValue: 1 << StationMessage.qm.rawValue)
    nonisolated(unsafe) public static let nil_ = StationMessages(rawValue: 1 << StationMessage.nil_.rawValue)
    nonisolated(unsafe) public static let garbage = StationMessages(rawValue: 1 << StationMessage.garbage.rawValue)
    nonisolated(unsafe) public static let rNR = StationMessages(rawValue: 1 << StationMessage.rNR.rawValue)
    nonisolated(unsafe) public static let rNR2 = StationMessages(rawValue: 1 << StationMessage.rNR2.rawValue)
    nonisolated(unsafe) public static let deMyCall1 = StationMessages(rawValue: 1 << StationMessage.deMyCall1.rawValue)
    nonisolated(unsafe) public static let deMyCall2 = StationMessages(rawValue: 1 << StationMessage.deMyCall2.rawValue)
    nonisolated(unsafe) public static let deMyCallNr1 = StationMessages(rawValue: 1 << StationMessage.deMyCallNr1.rawValue)
    nonisolated(unsafe) public static let deMyCallNr2 = StationMessages(rawValue: 1 << StationMessage.deMyCallNr2.rawValue)
    nonisolated(unsafe) public static let myCallNr1 = StationMessages(rawValue: 1 << StationMessage.myCallNr1.rawValue)
    nonisolated(unsafe) public static let myCallNr2 = StationMessages(rawValue: 1 << StationMessage.myCallNr2.rawValue)
    nonisolated(unsafe) public static let myCall2 = StationMessages(rawValue: 1 << StationMessage.myCall2.rawValue)
    nonisolated(unsafe) public static let nrQm = StationMessages(rawValue: 1 << StationMessage.nrQm.rawValue)
    nonisolated(unsafe) public static let longCQ = StationMessages(rawValue: 1 << StationMessage.longCQ.rawValue)
    nonisolated(unsafe) public static let qrl = StationMessages(rawValue: 1 << StationMessage.qrl.rawValue)
    nonisolated(unsafe) public static let qrl2 = StationMessages(rawValue: 1 << StationMessage.qrl2.rawValue)
    nonisolated(unsafe) public static let qsy = StationMessages(rawValue: 1 << StationMessage.qsy.rawValue)
    nonisolated(unsafe) public static let agn = StationMessages(rawValue: 1 << StationMessage.agn.rawValue)
}

/// Station operational states (Delphi `TStationState`):
/// - listening: waiting for the operator to send
/// - copying: operator's message is being transmitted
/// - preparingToSend: brief delay before transmitting a reply
/// - sending: transmitting its message
public enum StationState: Int {
    case listening = 0, copying, preparingToSend, sending
}

/// Events delivered by `Tick` (Delphi `TStationEvent`).
enum StationEvent: Int {
    case timeout = 0, msgSent, meStarted, meFinished
}

/// Whether the station is the user's own or a simulated DX station
/// (Delphi `TStationKind`).
enum StationKind: Int {
    case myStation = 0, dxStation
}

/// Requested message type for exchange-type queries (Delphi
/// `TRequestedMsgType`).
enum RequestedMsgType: Int {
    case sendMsg = 0, recvMsg
}

let never = Int.max

/// Base station (port of `TStation`).
public class Station {
    // ---- transmission state
    public var sendPos = 0
    /// Blocks remaining until evTimeout; `never` disables.
    public var timeout = 0
    /// Emit one LID-style corrupted serial.
    var nrWithError = false
    /// Random in [0,1) fixed at init — stable per-station decisions.
    var r1: Float = 0
    /// Linear sample amplitude.
    public var amplitude: Float = 0
    /// Sending speed (wpm, UI) and character speed (wpm, INI).
    public var wpmS = 0
    public var wpmC = 0
    /// Digitized CW envelope being transmitted.
    public var envelope: SampleArray?
    public var state: StationState = .listening

    // ---- contest exchange data
    var sentExchTypes = ExchTypes.undef
    public var nr = 0
    public var rst = 0
    public var myCall = ""
    public var hisCall = ""
    public var opName = ""
    var prec = ""
    var chk = 0
    var sect = ""
    public var exch1 = ""
    public var exch2 = ""
    var userText = ""
    var msgTemp = ""

    /// Message classes sent during the current transmission.
    public var msg = StationMessages.none
    /// Rendered text of the current message.
    public var msgText = ""

    // ---- sidetone oscillator
    var pitch = 0 {
        didSet {
            dPhi = Float(AudioConstants.twoPi) * Float(pitch) / Float(AudioConstants.defaultRate)
        }
    }
    private(set) var bfoPhase: Float = 0
    private var dPhi: Float = 0

    /// Returns the current oscillator phase and advances it (Delphi `Bfo`).
    var bfo: Float {
        let r = bfoPhase
        bfoPhase += dPhi
        if bfoPhase > Float(AudioConstants.twoPi) {
            bfoPhase -= Float(AudioConstants.twoPi)
        }
        return r
    }

    init() {
        initState()
    }

    /// Port of `TStation.Init`.
    func initState() {
        sentExchTypes = .undef
        msgTemp = "undef"
        r1 = Float.random(in: 0..<1)
    }

    /// Copy the next block of samples from the envelope (Delphi `GetBlock`).
    func getBlock() -> SampleArray {
        guard var env = envelope else { return [] }
        let count = min(Settings.bufSize, env.count - sendPos)
        let result = Array(env[sendPos..<(sendPos + count)])
        sendPos += Settings.bufSize
        if sendPos >= env.count {
            envelope = nil
        }
        return result
    }

    /// Queue a message for transmission (Delphi `SendMsg`).
    func sendMsg(_ aMsg: StationMessage) {
        assert(state == .preparingToSend || state == .sending || state == .listening)
        if envelope == nil { msg = [] }
        if aMsg == .none {
            state = .listening
            return
        }
        msg.insert(StationMessages(rawValue: 1 << aMsg.rawValue))
        // contest-specific message text
        Contest.shared?.sendMsg(self, aMsg)
    }

    /// Replace `<token>` markers with station-specific values and key the
    /// result out (Delphi `SendText`).
    func sendText(_ aMsg: String) {
        var msg = aMsg

        // '<#>' with error once, then plain
        if let range = msg.range(of: "<#>") {
            let txt = nrAsText()
            msg.replaceSubrange(range, with: txt)
        }
        msg = msg.replacingOccurrences(of: "<#>", with: nrAsText())

        // replace tokens with actual values
        var p = msg.range(of: "<")?.lowerBound
        while let pos = p {
            let q = pos
            if replaceToken(in: &msg, at: &p, token: "<my>", newText: myCall) { break }
            if replaceToken(in: &msg, at: &p, token: "<exch1>", newText: exch1) { break }
            if replaceToken(in: &msg, at: &p, token: "<exch2>", newText: exch2) { break }
            if replaceToken(in: &msg, at: &p, token: "<HisName>", newText: SimEngine.shared.uiHooks.userName) { break }
            if replaceToken(in: &msg, at: &p, token: "<MyName>", newText: Contest.shared?.me.opName ?? "") { break }
            if p == q {
                fatalError("TStation.SendText: unrecognized token in msg: \"\(msg)\"")
            }
        }

        if msgText != "" {
            msgText += " " + msg
        } else {
            msgText = msg
        }
        SimEngine.shared.debugCwStream?(msgText)
        sendMorse(Keyer.shared.encode(msgText))
    }

    /// Replace every successive occurrence of `token` at the current offset,
    /// advancing the offset to the next '<' (Delphi `ReplaceTokenAt`).
    private func replaceToken(in msg: inout String, at p: inout String.Index?, token: String, newText: String) -> Bool {
        while let pos = p, msg[pos...].hasPrefix(token) {
            let end = msg.index(pos, offsetBy: token.count)
            msg.replaceSubrange(pos..<end, with: newText)
            p = msg.range(of: "<", range: pos..<msg.endIndex)?.lowerBound
        }
        return p == nil
    }

    /// Key the encoded Morse message into the envelope (Delphi `SendMorse`).
    func sendMorse(_ aMorse: String) {
        if envelope == nil {
            sendPos = 0
            bfoPhase = 0
        }
        Keyer.shared.setWpm(wpmS, wpmC)
        Keyer.shared.morseMsg = aMorse
        var env = Keyer.shared.getEnvelope()
        for i in 0..<env.count {
            env[i] *= amplitude
        }
        envelope = env
        state = .sending
        timeout = never
    }

    /// Stop any in-flight transmission without generating a `msgSent` event.
    ///
    /// A normal abort (Esc) deliberately raises the message-sent event so the
    /// contest state machine can continue.  At the end of a timed run there
    /// must be no such follow-up: an unfinished transmission is not a
    /// completed QSO and must remain unverified.
    func stopTransmission() {
        envelope = nil
        sendPos = 0
        msg = .none
        msgText = ""
        timeout = never
        state = .listening
    }

    /// Per-block simulation step (Delphi `Tick`).
    func tick() {
        if state == .sending && envelope == nil {
            // just finished sending
            msgText = ""
            state = .listening
            processEvent(.msgSent)
        } else if state != .sending {
            if timeout > -1 { timeout -= 1 }
            if timeout == 0 { processEvent(.timeout) }
        }
    }

    /// Format the exchange string to be sent (Delphi `NrAsText`), with
    /// LID errors and cut-number substitutions.
    func nrAsText() -> String {
        let simContest = Settings.simContest
        var result: String

        switch simContest {
        case .cwt:
            result = "\(exch1)  \(exch2)"
        case .naQp:
            if exch2.isEmpty {
                result = exch1
            } else {
                result = "\(exch1) \(exch2)"
            }
        case .arrlSS:
            if call == myCall {
                result = "\(nr)\(exch1) \(myCall) \(exch2)"
            } else {
                result = "\(exch1) \(myCall) \(exch2)"
            }
        case .wpx, .hst:
            if call == myCall {
                result = String(format: "%d%03d", rst, nr)
            } else {
                let range = Settings.serialNRSettings[Settings.serialNR]!
                var digits: Int
                if r1 < 0.5 {
                    digits = range.minDigits
                } else {
                    digits = Int(floor(log10(Float(range.minVal)) + 1))
                }
                result = String(format: "%d%0*d", rst, digits, nr)
            }
        default:
            result = "\(exch1) \(exch2)"
        }

        // LID: corrupt one digit of the serial
        if nrWithError && sentExchTypes.exch2 == .serialNr {
            var idx = result.count - 1
            var chars = Array(result)
            if !(chars[idx].isWholeNumber && chars[idx] >= "2" && chars[idx] <= "7") {
                idx -= 1
            }
            if chars[idx].isWholeNumber && chars[idx] >= "2" && chars[idx] <= "7" {
                if Float.random(in: 0..<1) < 0.5 {
                    chars[idx] = Character(String(Int(String(chars[idx]))! - 1))
                } else {
                    chars[idx] = Character(String(Int(String(chars[idx]))! + 1))
                }
                result = String(chars) + String(format: "EEEEE %03d", nr)
            }
            nrWithError = false
        }

        let isDxStation = myCall != Settings.call
        if sentExchTypes.exch1 == .rst {
            if Settings.runMode != .hst && isDxStation && Float.random(in: 0..<1) < 0.05 {
                result = result.replacingOccurrences(of: "599", with: "ENN")
            }
            result = result.replacingOccurrences(of: "599", with: "5NN")
        }

        if Settings.runMode != .hst && [.serialNr, .cqZone, .ituZone, .age, .power].contains(sentExchTypes.exch2) {
            // replace leading zeros
            result = result.replacingOccurrences(of: "000", with: "TTT")
            result = result.replacingOccurrences(of: "00", with: "TT")
            if sentExchTypes.exch2 == .serialNr && Float.random(in: 0..<1) < 0.98 {
                result = result.replacingOccurrences(of: "0", with: "T")
            }

            // the user's station always sends cut numeric fields
            if !isDxStation {
                result = result.replacingOccurrences(of: "0", with: "T")
                result = result.replacingOccurrences(of: "9", with: "N")
                if sentExchTypes.exch2 == .cqZone {
                    result = result.replacingOccurrences(of: "1", with: "A")
                }
            } else if Float.random(in: 0..<1) < 0.4 && sentExchTypes.exch2 != .cqZone {
                result = result.replacingOccurrences(of: "0", with: "O")
            } else if Float.random(in: 0..<1) < 0.97 && sentExchTypes.exch2 != .cqZone {
                result = result.replacingOccurrences(of: "0", with: "T")
            }

            if [.cqZone, .power].contains(sentExchTypes.exch2) {
                if r1 < 0.70 {
                    result = result.replacingOccurrences(of: "0", with: "T")
                    result = result.replacingOccurrences(of: "1", with: "A")
                    result = result.replacingOccurrences(of: "9", with: "N")
                }
            } else if Float.random(in: 0..<1) < 0.97 {
                result = result.replacingOccurrences(of: "9", with: "N")
            }
        }

        // JARL ALLJA/ACAG cut numbers
        if Settings.runMode != .hst && [.jaPref, .jaCity].contains(sentExchTypes.exch2) && isDxStation {
            let r = Float.random(in: 0..<1)
            if r < 0.4 {
                result = result.replacingOccurrences(of: "00", with: "TT")
                result = result.replacingOccurrences(of: "0", with: "O")
            } else if r < 0.8 {
                result = result.replacingOccurrences(of: "0", with: "T")
            }
            if Float.random(in: 0..<1) < 0.1 {
                result = result.replacingOccurrences(of: "9", with: "N")
            }
        }
        return result
    }

    func wpmAsText() -> String {
        if wpmS < wpmC {
            return String(format: "%d/%d", wpmS, wpmC)
        }
        return String(format: "%3d", wpmS)
    }

    /// Process a station event (Delphi `ProcessEvent`, abstract).
    func processEvent(_ event: StationEvent) {
        fatalError("Station.processEvent must be overridden")
    }
}

extension Station {
    /// Convenience accessor mirroring the Delphi unit-global `Call`.
    var call: String { Settings.call }
}

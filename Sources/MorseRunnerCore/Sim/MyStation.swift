// Port of MyStn.pas — the user's own station.
//
// Distinctive behavior: outgoing text is split into pieces around the
// '<his>' token so the callsign can be corrected mid-transmission
// (UpdateCallInMessage), and pieces are sent sequentially as the envelope
// drains (GetBlock).

import Foundation

/// The user's station (port of `TMyStation`).
public final class MyStation: Station {
    /// Message pieces split around '<his>'; '@' marks the callsign position.
    private var pieces: [String] = []
    /// Extra silence committed when a suffix was typed during the call's
    /// final gap. Keep it when subsequent edits rebuild the same prefix.
    private struct CallGap {
        let prefix: String
        let position: Int  // sample position before any extra gaps
        let count: Int
    }
    private var callGaps: [CallGap] = []
    private var callSpeed = (wpmS: 0, wpmC: 0)
    /// DXCC entity of the user's call (for user-text status filtering).
    var myEntity = ""

    override init() {
        super.init()
        initStation()
    }

    /// Port of `TMyStation.Init`.
    func initStation() {
        super.initState()
        myCall = Settings.call
        nr = 1
        rst = 599
        pitch = Settings.pitch
        wpmS = Settings.wpm
        wpmC = wpmS
        amplitude = 300000

        // invalid until Tst.OnSetMyCall() sets it
        sentExchTypes = .undef

        opName = Settings.hamName
        exch1 = "3A"
        exch2 = "OR"

        myEntity = ""
        if let rec = Dxcc.shared.findRec(myCall) {
            myEntity = rec.entity
        }
    }

    /// Called by the UI whenever Wpm is updated.
    func setWpm(_ aWpmS: Int) {
        if Settings.allStationsWpmS > 0 {
            wpmS = Settings.allStationsWpmS
        } else {
            wpmS = aWpmS
        }
        if Contest.shared?.isFarnsworthAllowed == true && Settings.farnsworthCharRate > wpmS {
            wpmC = Settings.farnsworthCharRate
        } else {
            wpmC = wpmS
        }
    }

    override func processEvent(_ event: StationEvent) {
        if event == .msgSent {
            Contest.shared?.onMeFinishedSending()
        }
    }

    /// Abort the current transmission (Delphi `AbortSend`).
    func abortSend() {
        envelope = nil
        msg = .garbage
        msgText = ""
        pieces = []
        callGaps.removeAll()
        state = .listening
        processEvent(.msgSent)
    }

    /// End-of-run stop that must not call `onMeFinishedSending` or advance the
    /// DX state machine.  Clear the queued callsign pieces as well as the
    /// base station's current envelope.
    override func stopTransmission() {
        super.stopTransmission()
        pieces.removeAll()
        callGaps.removeAll()
    }

    override func sendText(_ aMsg: String) {

        // some exchange field types have specific behaviors
        if sentExchTypes.exch1 == .opName {
            assert(opName == Settings.hamName, "HamName doesn't change; should already be set")
            opName = Settings.hamName
        }

        addToPieces(aMsg)

        if state != .sending {
            sendNextPiece()
            Contest.shared?.onMeStartedSending()
        }
    }

    /// Split the message around '<his>' into pieces (Delphi `AddToPieces`).
    private func addToPieces(_ aMsg: String) {
        var msg = aMsg
        var p = msg.range(of: "<his>")?.lowerBound
        while p != nil {
            if let pos = p {
                if pos > msg.startIndex {
                    pieces.append(String(msg[msg.startIndex..<pos]))
                }
                pieces.append("@")  // callsign indicator
                msg = String(msg[msg.index(pos, offsetBy: 5)...])
            }
            p = msg.range(of: "<his>")?.lowerBound
        }
        if !msg.isEmpty {
            pieces.append(msg)
        }

        // remove empty pieces (shouldn't be any)
        pieces.removeAll { $0.isEmpty }
    }

    private func sendNextPiece() {
        msgText = ""
        callGaps.removeAll()
        callSpeed = (wpmS, wpmC)

        if pieces.first != "@" {
            super.sendText(pieces[0])
        } else if Settings.callsFromKeyer && !(Settings.runMode == .hst || Settings.runMode == .wpx) {
            super.sendText(" ")
        } else {
            super.sendText(hisCall)
        }
    }

    override func getBlock() -> SampleArray {
        let result = super.getBlock()
        if envelope == nil {
            if !pieces.isEmpty { pieces.removeFirst() }
            if !pieces.isEmpty { sendNextPiece() }
            // cursor to exchange field (original: only when MainForm.MustAdvance)
            if SimEngine.shared.mustAdvance {
                SimEngine.shared.mustAdvance = false
                SimEngine.shared.uiHooks.onAdvance?()
            }
        }
        return result
    }

    /// Try to change the callsign currently being sent (Delphi
    /// `UpdateCallInMessage`).
    @discardableResult
    public func updateCallInMessage(_ aCall: String) -> Bool {
        guard !aCall.isEmpty else { return false }
        var result = false

        // are we sending the call now?
        result = !pieces.isEmpty && pieces[0] == "@"

        // is the already sent part the same as in the new call?
        if result {
            // create new envelope
            // A WPM change takes effect on the next piece. Rebuilding this
            // call must retain the timing of the samples already queued.
            Keyer.shared.setWpm(callSpeed.wpmS, callSpeed.wpmC)
            Keyer.shared.morseMsg = Keyer.shared.encode(aCall)
            var newEnvelope = Keyer.shared.getEnvelope()
            for i in 0..<newEnvelope.count {
                newEnvelope[i] *= amplitude
            }

            var gaps = callGaps.filter { aCall.hasPrefix($0.prefix) && aCall != $0.prefix }
            var addedSilence = 0
            for gap in gaps {
                newEnvelope.insert(contentsOf: repeatElement(Float(0), count: gap.count),
                                   at: gap.position + addedSilence)
                addedSilence += gap.count
            }

            // compare with the old one
            // The current envelope may have drained between the text-change
            // notification and this callback.  Do not subscript a missing or
            // shorter envelope while checking the already-sent prefix.
            if let currentEnvelope = envelope, sendPos <= currentEnvelope.count,
               newEnvelope.count >= sendPos {
                if let mismatch = (0..<sendPos).first(where: { currentEnvelope[$0] != newEnvelope[$0] }) {
                    // An appended letter normally starts after 3U, but the
                    // short call had an end-of-message gap (and block padding).
                    // If that silence has already left the station, delay the
                    // new letter rather than rejecting it or clipping its start.
                    if !msgText.isEmpty, aCall.hasPrefix(msgText),
                       currentEnvelope[mismatch...].allSatisfy({ $0 == 0 }) {
                        let delay = sendPos - mismatch
                        newEnvelope.insert(contentsOf: repeatElement(Float(0), count: delay), at: mismatch)
                        gaps.append(CallGap(prefix: msgText, position: mismatch - addedSilence, count: delay))
                    } else {
                        result = false
                    }
                }
            } else {
                result = false
            }

            if result {
                let padding = (Keyer.shared.bufSize - newEnvelope.count % Keyer.shared.bufSize) % Keyer.shared.bufSize
                newEnvelope.append(contentsOf: repeatElement(Float(0), count: padding))
                envelope = newEnvelope
                hisCall = aCall
                msgText = aCall
                callGaps = gaps
            }
        }

        // could not correct the current message, but another call is scheduled
        if !result {
            // `1..<0` is an invalid Swift range and traps.  `dropFirst()`
            // safely produces an empty collection when no suffix is queued.
            for i in pieces.indices.dropFirst() where pieces[i] == "@" {
                hisCall = aCall
                return true
            }
        }
        return result
    }
}

// Runtime context shared by the simulation engine and the UI.
//
// The Delphi original wires everything through global singletons
// (Tst: TContest, Keyer: TKeyer, MainForm.*, Log.*). This port keeps the
// same shape: `SimEngine.shared` owns the contest and the UI-facing hooks
// the engine calls back into.

import Foundation

/// One row of the on-screen score table (port of Log.ScoreTableInsert).
public struct ScoreTableRow {
    public let columns: [String]
}

/// Score summary (port of Log.UpdateStats).
public struct ScoreSummary {
    /// Number of QSOs currently in the log (including those with errors).
    public let qsoCount: Int
    /// Number of QSOs that have been verified as error-free.
    public let verifiedQsoCount: Int
    public let points: Int
    public let mults: Int
    public let verifiedPoints: Int
    public let verifiedMults: Int
}

/// Callbacks the engine uses to reach UI state (port of the direct
/// `MainForm.xxx` references in the Delphi units).
public struct UIHooks {
    // ---- input state
    /// User's operator name (MainForm.Edit2.Text for '<HisName>').
    public var userName: String = ""
    /// Current text of the callsign entry field (MainForm.Edit1.Text).
    public var enteredCall: String = ""
    /// Exchange field 1 text (MainForm.Edit2.Text).
    public var enteredExch1: String = ""
    /// Exchange field 2 text (MainForm.Edit3.Text).
    public var enteredExch2: String = ""
    /// Received exchange types for the current entry (MainForm.RecvExchTypes).
    public var recvExchTypes = ExchTypes.undef
    /// Self-monitor volume slider value, 0..1 (MainForm.VolumeSlider1.Value).
    public var volume: Float = 0.04

    // ---- display updates
    /// Add a row to the score table (Log.ScoreTableInsert).
    public var onScoreTableInsert: ((ScoreTableRow) -> Void)?
    /// Update an existing row (used when QSO errors are (re)computed).
    public var onScoreTableUpdate: ((Int, ScoreTableRow) -> Void)?
    /// Update the score summary (Log.UpdateStats).
    public var onStatsUpdate: ((ScoreSummary) -> Void)?
    /// Update the rate label, qso/hr (Log.ShowRate).
    public var onRateUpdate: ((Int) -> Void)?
    /// Update the clock label (MainForm.Panel2).
    public var onClockUpdate: ((String) -> Void)?
    /// Update the pile-up count label (MainForm.Panel4).
    public var onPileupCount: ((Int) -> Void)?
    /// Update the status bar (MainForm.sbar). isError selects color.
    public var onStatusBar: ((String, Bool) -> Void)?
    /// Update the exchange field caption label (MainForm.Label3).
    public var onExchangeLabel: ((String) -> Void)?
    /// Clear the entry fields (MainForm.WipeBoxes).
    public var onWipeBoxes: (() -> Void)?
    /// Move the cursor to the exchange field (MainForm.Advance).
    public var onAdvance: (() -> Void)?
    /// Stop the run and show the end-of-run score dialog
    /// (MainForm.Run(rmStop) + PopupScoreWpx/Hst).
    public var onRunStopped: (() -> Void)?
    /// Update the HST score label (MainForm.Panel11).
    public var onHstScore: ((Int) -> Void)?
    /// Final output audio block (for WAV recording, AlWavFile1).
    public var onOutputBlock: ((SampleArray) -> Void)?
    /// Operator name changed (updates title bar / '<HisName>').
    public var onUserNameChange: ((String) -> Void)?
    /// Run state changed (enable/disable controls).
    public var onRunState: ((RunMode) -> Void)?
    /// Received exchange types changed (labels/max lengths).
    public var onRecvExchTypes: ((ExchTypes) -> Void)?
    /// End-of-run score dialog for competition modes (PopupScoreWpx/Hst).
    public var onShowScore: (() -> Void)?
}

/// Engine runtime singleton.
public final class SimEngine {
    public nonisolated(unsafe) static let shared = SimEngine()

    /// Live contest instance (port of the `Tst` global).
    nonisolated(unsafe) var contest: Contest?

    /// UI-facing hooks.
    public nonisolated(unsafe) var uiHooks = UIHooks()

    /// Debug: stream decoded CW text (DebugCwDecoder).
    public nonisolated(unsafe) var debugCwStream: ((String) -> Void)?
    /// Debug: ghosting messages (DebugGhosting).
    public nonisolated(unsafe) var debugGhosting: ((String) -> Void)?

    /// Called by the UI when the simulation should stop (FStopPressed).
    nonisolated(unsafe) var stopRequested = false

    /// Port of MainForm.MustAdvance: the entry focus should advance to the
    /// exchange field only right after the user pressed Enter on a call,
    /// not on every transmitted envelope (original MyStn.GetBlock checks
    /// `if MainForm.MustAdvance then MainForm.Advance`).
    nonisolated(unsafe) var mustAdvance = false

    /// Guards the end-of-run handling so it fires only once while the audio
    /// pump winds down asynchronously.
    nonisolated(unsafe) var stopHandled = false

    /// True when the run ended because the time limit expired (not because
    /// the user pressed Stop). Original: WPX shows its score dialog only on
    /// time expiry.
    nonisolated(unsafe) var runExpired = false

    private init() {}
}

// Port of Ini.pas — the global settings singleton.
//
// The Delphi version keeps every setting in unit-level `var`s persisted to a
// Windows INI file (MorseRunner.ini). This port keeps the same names and
// defaults and persists via UserDefaults using the same [Section]/Key scheme.

import Foundation

/// Contest identifiers (Delphi `TSimContest`). Order must match
/// `ContestDefinitions` — INI files store the raw ordinal.
public enum SimContest: Int, CaseIterable {
    case wpx = 0, cwt, fieldDay, naQp, hst, cqww, arrlDx, sst, allJa, acag, iaruHf, arrlSS
}

/// Simulation run modes (Delphi `TRunMode`).
public enum RunMode: Int, CaseIterable {
    case stop = 0, pileup, single, wpx, hst
}

/// Serial number generation modes (Delphi `TSerialNRTypes`).
public enum SerialNRType: Int, CaseIterable {
    case startContest = 0, midContest, endContest, customRange
}

/// Exchange field #1 types (Delphi `TExchange1Type`).
public enum Exchange1Type: Int, CaseIterable {
    case undef = -1, rst, opName, fdClass, ssNrPrecedence
}

/// Exchange field #2 types (Delphi `TExchange2Type`).
public enum Exchange2Type: Int, CaseIterable {
    case undef = -1, serialNr, genericField, arrlSection, stateProv, cqZone, ituZone,
         age, power, jaPref, jaCity, naQpExch2, naQpNonNaExch2, ssCheckSection
}

/// Pair of exchange field types (Delphi `TExchTypes`, Station.pas).
public struct ExchTypes: Equatable {
    public var exch1: Exchange1Type
    public var exch2: Exchange2Type

    nonisolated(unsafe) public static let undef = ExchTypes(exch1: .undef, exch2: .undef)
}

/// Field definition: caption, validation regex, max length (Delphi `TFieldDefinition`).
public struct FieldDefinition {
    public let caption: String
    public let regex: String
    public let maxLength: Int
}

/// Exchange field #1 settings (Delphi `Exchange1Settings`).
nonisolated(unsafe) public let exchange1Settings: [Exchange1Type: FieldDefinition] = [
    .rst:            FieldDefinition(caption: "RST",   regex: "[1-5E][1-9N][1-9N]",          maxLength: 3),
    .opName:         FieldDefinition(caption: "Name",  regex: "[A-Z][A-Z]*",                 maxLength: 10),
    .fdClass:        FieldDefinition(caption: "Class", regex: "[1-9][0-9]*[A-F]",            maxLength: 3),
    // ARRL SS does not parse user-entered Exchange 1 field; Exchange 2 is used.
    .ssNrPrecedence: FieldDefinition(caption: "",      regex: "([0-9]+|#)? *[QABUMS]",       maxLength: 4),
]

/// Exchange field #2 settings (Delphi `Exchange2Settings`).
nonisolated(unsafe) public let exchange2Settings: [Exchange2Type: FieldDefinition] = [
    .serialNr:       FieldDefinition(caption: "Nr.",           regex: "([0-9OTN]+)|(#)",              maxLength: 4),
    .genericField:   FieldDefinition(caption: "Exch",          regex: "[0-9A-Z]*",                    maxLength: 12),
    .arrlSection:    FieldDefinition(caption: "Section",       regex: "([A-Z][A-Z])|([A-Z][A-Z][A-Z])", maxLength: 3),
    .stateProv:      FieldDefinition(caption: "State/Prov",    regex: "[ABCDFGHIKLMNOPQRSTUVWY][ABCDEFHIJKLMNORSTUVXYZ]", maxLength: 6),
    .cqZone:         FieldDefinition(caption: "CQ-Zone",       regex: "[0-9OANT]+",                   maxLength: 2),
    .ituZone:        FieldDefinition(caption: "Zone",          regex: "[0-9]*",                       maxLength: 4),
    .age:            FieldDefinition(caption: "Age",           regex: "[0-9][0-9]",                   maxLength: 2),
    .power:          FieldDefinition(caption: "Power",         regex: "([0-9]*)|(K)|(KW)|([0-9A]*[OTN]*)", maxLength: 4),
    .jaPref:         FieldDefinition(caption: "Number",        regex: "([0-9AOTN]*)([LMHP])",         maxLength: 4),
    .jaCity:         FieldDefinition(caption: "Number",        regex: "([0-9AOTN]*)([LMHP])",         maxLength: 7),
    .naQpExch2:      FieldDefinition(caption: "State",         regex: "([0-9A-Z/]*)",                 maxLength: 6),
    .naQpNonNaExch2: FieldDefinition(caption: "State",         regex: "()|([0-9A-Z/]*)",              maxLength: 6),
    .ssCheckSection: FieldDefinition(caption: "Nr Prec CK Sect", regex: "[0-9ONT]{1,2} +[A-Z]{2,3}",  maxLength: 32),
]

/// Contest definition (Delphi `TContestDefinition`).
public struct ContestDefinition {
    public let name: String
    public let key: String
    public let exchType1: Exchange1Type
    public let exchType2: Exchange2Type
    public var exchCaptions: [String]
    public let exchFieldEditable: Bool
    public let exchDefault: String
    public let msg: String
}

let defaultWebServer = "http://www.dxatlas.com/MorseRunner/MrScore.asp"

/// Ordered contest definitions (Delphi `ContestDefinitions`). Order must
/// match `SimContest` raw values — settings persist the ordinal.
nonisolated(unsafe) public let contestDefinitions: [ContestDefinition] = [
    ContestDefinition(name: "CQ WPX", key: "CqWpx",
        exchType1: .rst, exchType2: .serialNr,
        exchCaptions: ["RST", "Nr."], exchFieldEditable: true,
        exchDefault: "5NN #", msg: "'RST <serial>' (e.g. 5NN #|123)"),
    ContestDefinition(name: "CWOPS CWT", key: "Cwt",
        exchType1: .opName, exchType2: .genericField,
        exchCaptions: ["Name", "Exch"], exchFieldEditable: true,
        exchDefault: "DAVID 123", msg: "'<op name> <CWOPS Number|State|Country>' (e.g. DAVID 123)"),
    ContestDefinition(name: "ARRL Field Day", key: "ArrlFd",
        exchType1: .fdClass, exchType2: .arrlSection,
        exchCaptions: ["Class", "Section"], exchFieldEditable: true,
        exchDefault: "3A OR", msg: "'<class> <section>' (e.g. 3A OR)"),
    ContestDefinition(name: "NCJ NAQP", key: "NAQP",
        exchType1: .opName, exchType2: .naQpExch2,
        exchCaptions: ["Name", "State"], exchFieldEditable: true,
        exchDefault: "ALEX ON", msg: "'<name> [<state|prov|dxcc-entity>]' (e.g. ALEX ON)"),
    ContestDefinition(name: "HST (High Speed Test)", key: "HST",
        exchType1: .rst, exchType2: .serialNr,
        exchCaptions: ["RST", "Nr."], exchFieldEditable: false,
        exchDefault: "5NN #", msg: "'RST <serial>' (e.g. 5NN #)"),
    ContestDefinition(name: "CQ WW", key: "CQWW",
        exchType1: .rst, exchType2: .cqZone,
        exchCaptions: ["RST", "CQ-Zone"], exchFieldEditable: true,
        exchDefault: "5NN 24", msg: "'RST <cq-zone>' (e.g. 5NN 24)"),
    ContestDefinition(name: "ARRL DX", key: "ArrlDx",
        exchType1: .rst, exchType2: .stateProv,
        exchCaptions: ["RST", "State/Prov"], exchFieldEditable: true,
        exchDefault: "5NN ON", msg: "'RST <state|province|power>' (e.g. 5NN ON)"),
    ContestDefinition(name: "K1USN Slow Speed Test", key: "Sst",
        exchType1: .opName, exchType2: .genericField,
        exchCaptions: ["Name", "State/Prov/DX"], exchFieldEditable: true,
        exchDefault: "BRUCE MA", msg: "'<op name> <State|Prov|DX>' (e.g. BRUCE MA)"),
    ContestDefinition(name: "JARL ALL JA", key: "AllJa",
        exchType1: .rst, exchType2: .jaPref,
        exchCaptions: ["RST", "Number"], exchFieldEditable: true,
        exchDefault: "5NN 10H", msg: "'RST <Pref><Power>' (e.g. 5NN 10H)"),
    ContestDefinition(name: "JARL ACAG", key: "Acag",
        exchType1: .rst, exchType2: .jaCity,
        exchCaptions: ["RST", "Number"], exchFieldEditable: true,
        exchDefault: "5NN 1002H", msg: "'RST <City|Gun|Ku><Power>' (e.g. 5NN 1002H)"),
    ContestDefinition(name: "IARU HF", key: "IaruHf",
        exchType1: .rst, exchType2: .genericField,
        exchCaptions: ["RST", "Zone/Soc"], exchFieldEditable: true,
        exchDefault: "5NN 6", msg: "'RST <Itu-zone|IARU Society>' (e.g. 5NN 6)"),
    ContestDefinition(name: "ARRL Sweepstakes", key: "SSCW",
        exchType1: .ssNrPrecedence, exchType2: .ssCheckSection,
        exchCaptions: ["Nr", "Prec CK Sect"], exchFieldEditable: true,
        exchDefault: "A 72 OR", msg: "'[#|123] <precedence> <check> <section>' (e.g. A 72 OR)"),
]

/// Serial-number range settings (Delphi `TSerialNRSettings`).
public struct SerialNumberSettings {
    public var key: String
    public var rangeStr: String
    public var minVal: Int
    public var maxVal: Int
    public var minDigits: Int
    public var maxDigits: Int

    public var isValid: Bool { minVal > 0 && minVal <= maxVal }

    /// Random serial number within [minVal, maxVal] (Delphi `GetNR`).
    public func getNR() -> Int {
        if isValid {
            return minVal + Int.random(in: 0..<(maxVal - minVal))
        }
        return 1
    }

    /// Parse a "min-max" range spec (Delphi `ParseSerialNR`). Returns nil on
    /// error with the error text.
    public static func parse(_ valueStr: String, into s: inout SerialNumberSettings) -> String? {
        s.rangeStr = valueStr
        let parts = valueStr.split(separator: "-")
        var err: String?
        if parts.count != 2 || valueStr.filter({ $0 == "-" }).count != 1
            || Int(parts[0]) == nil || Int(parts[1]) == nil {
            err = "Error: '\(valueStr)' is an invalid range.\nExpecting min-max values with up to 4-digits each (e.g. 100-300)."
        } else if let mn = Int(parts[0]), let mx = Int(parts[1]) {
            if mn > 9999 || mx > 9999 {
                err = "Error: '\(valueStr)' is an invalid range.\nExpecting range values to be less than or equal to 9999."
            } else if mn > mx {
                err = "Error: '\(valueStr)' is an invalid range.\nExpecting Min value to be less than Max value."
            } else {
                s.minVal = mn
                s.maxVal = mx
                s.minDigits = parts[0].count
                s.maxDigits = parts[1].count
            }
        }
        if err != nil {
            s.minDigits = 0
            s.maxDigits = 0
        }
        return err
    }
}

/// Global settings singleton (port of Ini.pas unit-level vars).
public enum Settings {
    // ---- Station
    public nonisolated(unsafe) static var call = "BH5HIE"
    public nonisolated(unsafe) static var hamName = "BH5HIE"
    public nonisolated(unsafe) static var arrlClass = "3A"
    public nonisolated(unsafe) static var arrlSection = "GH"
    public nonisolated(unsafe) static var wpm = 25
    public nonisolated(unsafe) static var wpmStepRate = 2
    public nonisolated(unsafe) static var maxRxWpm = 0
    public nonisolated(unsafe) static var minRxWpm = 0
    public nonisolated(unsafe) static var nRDigits = 1
    public nonisolated(unsafe) static var serialNRSettings: [SerialNRType: SerialNumberSettings] = [
        .startContest: SerialNumberSettings(key: "SerialNrStartContest", rangeStr: "Default", minVal: 1, maxVal: 176, minDigits: 1, maxDigits: 3),
        .midContest:   SerialNumberSettings(key: "SerialNrMidContest",   rangeStr: "50-500",   minVal: 50,  maxVal: 500,  minDigits: 2, maxDigits: 3),
        .endContest:   SerialNumberSettings(key: "SerialNrEndContest",   rangeStr: "500-5000", minVal: 500, maxVal: 5000, minDigits: 3, maxDigits: 4),
        .customRange:  SerialNumberSettings(key: "SerialNrCustomRange",  rangeStr: "01-99",    minVal: 1,   maxVal: 99,   minDigits: 2, maxDigits: 2),
    ]
    public nonisolated(unsafe) static var serialNR: SerialNRType = .startContest

    // ---- Band / Rx
    public nonisolated(unsafe) static var bandWidth = 500
    public nonisolated(unsafe) static var pitch = 600
    public nonisolated(unsafe) static var qsk = false
    public nonisolated(unsafe) static var rit = 0
    public nonisolated(unsafe) static var ritStepIncr = 50
    public nonisolated(unsafe) static var bufSize = AudioConstants.defaultBufSize

    // ---- Simulation
    public nonisolated(unsafe) static var activity = 2
    public nonisolated(unsafe) static var qrn = false
    public nonisolated(unsafe) static var qrm = false
    public nonisolated(unsafe) static var qsb = false
    public nonisolated(unsafe) static var flutter = false
    public nonisolated(unsafe) static var lids = false
    public nonisolated(unsafe) static var nilInstantRemove = true
    public nonisolated(unsafe) static var noActivityCnt = 0
    public nonisolated(unsafe) static var noStopActivity = 0
    public nonisolated(unsafe) static var getWpmUsesGaussian = false
    public nonisolated(unsafe) static var showCheckSection = 50
    public nonisolated(unsafe) static var showExchangeSummary = true

    // ---- Contest
    public nonisolated(unsafe) static var duration = 30
    public nonisolated(unsafe) static var runMode: RunMode = .stop
    public nonisolated(unsafe) static var defaultRunMode: RunMode = .pileup
    public nonisolated(unsafe) static var hiScore = 0
    public nonisolated(unsafe) static var compDuration = 60
    public nonisolated(unsafe) static var simContest: SimContest = .wpx
    public nonisolated(unsafe) static var activeContest: ContestDefinition { contestDefinitions[simContest.rawValue] }
    public nonisolated(unsafe) static var userExchangeTbl = [String](repeating: "", count: SimContest.allCases.count)
    public nonisolated(unsafe) static var userExchange1 = [String](repeating: "", count: SimContest.allCases.count)
    public nonisolated(unsafe) static var userExchange2 = [String](repeating: "", count: SimContest.allCases.count)

    // ---- Station audio
    public nonisolated(unsafe) static var monLevel = -15        // dB, range [-60, 0]
    public nonisolated(unsafe) static var saveWav = false

    // ---- Settings
    public nonisolated(unsafe) static var farnsworthCharRate = 25
    public nonisolated(unsafe) static var allStationsWpmS = 0   // force all stations to this Wpm
    public nonisolated(unsafe) static var callsFromKeyer = false
    public nonisolated(unsafe) static var stationIdRate = 3
    public nonisolated(unsafe) static var singleCallStartDelay = 0
    public nonisolated(unsafe) static var webServer = ""
    public nonisolated(unsafe) static var submitHiScoreURL = ""
    public nonisolated(unsafe) static var postMethod = "POST"
    public nonisolated(unsafe) static var showCallsignInfo = 1

    // ---- Debug
    public nonisolated(unsafe) static var debugExchSettings = false
    public nonisolated(unsafe) static var debugCwDecoder = false
    public nonisolated(unsafe) static var debugGhosting = false
    public nonisolated(unsafe) static var f8 = ""

    /// Defaults for every persistable key, so settings can be reset.
    public nonisolated(unsafe) static let defaults: [String: Any] = [
        "Contest.SimContest": SimContest.wpx.rawValue,
        "Contest.DefaultRunMode": RunMode.pileup.rawValue,
        "Station.Call": "VE3NEA",
        "Station.ArrlClass": "3A",
        "Station.ArrlSection": "ON",
        "Station.Wpm": 25,
        "Station.Qsk": false,
        "Station.CallsFromKeyer": false,
        "Station.GetWpmUsesGaussian": false,
        "Band.Activity": 2,
        "Band.Qrn": false,
        "Band.Qrm": false,
        "Band.Qsb": false,
        "Band.Flutter": false,
        "Band.Lids": false,
        "Contest.Duration": 30,
        "Contest.HiScore": 0,
        "Contest.CompetitionDuration": 60,
        "System.WebServer": defaultWebServer,
        "System.SubmitHiScoreURL": "",
        "System.PostMethod": "POST",
        "System.ShowCallsignInfo": true,
        "System.BufSize": 3,
        "Station.SelfMonVolume": -15,
        "Station.SaveWav": false,
        "Settings.FarnsworthCharacterRate": 25,
        "Settings.WpmStepRate": 2,
        "Settings.RitStepIncr": 50,
        "Settings.ShowCheckSection": 50,
        "Settings.ShowExchangeSummary": true,
        "Settings.StationIdRate": 3,
        "Settings.SingleCallStartDelay": 0,
        "Settings.NilInstantRemove": true,
        "Debug.DebugExchSettings": false,
        "Debug.DebugCwDecoder": false,
        "Debug.DebugGhosting": false,
        "Debug.AllStationsWpmS": 0,
        "Debug.F8": "",
    ]

    /// Load persisted settings into the singleton (port of `Ini.FromIni`).
    /// Runs after the UI exists, so UI-only knobs are applied by callers.
    public static func loadFromDefaults() {
        let d = UserDefaults.standard
        let secs: [String: [String]] = [
            "Contest": ["SimContest", "DefaultRunMode", "Duration", "HiScore", "CompetitionDuration"],
            "Station": ["Call", "ArrlClass", "ArrlSection", "Wpm", "Qsk", "CallsFromKeyer",
                        "GetWpmUsesGaussian", "SelfMonVolume", "SaveWav"],
            "Band": ["Activity", "Qrn", "Qrm", "Qsb", "Flutter", "Lids"],
            "System": ["WebServer", "SubmitHiScoreURL", "PostMethod", "ShowCallsignInfo", "BufSize"],
            "Settings": ["FarnsworthCharacterRate", "WpmStepRate", "RitStepIncr",
                         "ShowCheckSection", "ShowExchangeSummary", "StationIdRate",
                         "SingleCallStartDelay", "NilInstantRemove"],
            "Debug": ["DebugExchSettings", "DebugCwDecoder", "DebugGhosting", "AllStationsWpmS", "F8"],
        ]
        // Register defaults so reads never throw
        d.register(defaults: Settings.defaults)

        let v = d.integer(forKey: "Contest.SimContest")
        simContest = SimContest(rawValue: v) ?? .wpx
        if let rm = RunMode(rawValue: d.integer(forKey: "Contest.DefaultRunMode")) {
            defaultRunMode = rm
        }
        duration = d.integer(forKey: "Contest.Duration")
        hiScore = d.integer(forKey: "Contest.HiScore")
        compDuration = max(1, min(60, d.integer(forKey: "Contest.CompetitionDuration")))

        call = d.string(forKey: "Station.Call") ?? call
        for i in 0..<userExchangeTbl.count {
            if let v = d.string(forKey: "Station.Exchange.\(i)") {
                userExchangeTbl[i] = v
            }
        }
        arrlClass = d.string(forKey: "Station.ArrlClass") ?? arrlClass
        arrlSection = d.string(forKey: "Station.ArrlSection") ?? arrlSection
        wpm = d.integer(forKey: "Station.Wpm")
        maxRxWpm = d.integer(forKey: "Station.CWMaxRxSpeed")
        minRxWpm = d.integer(forKey: "Station.CWMinRxSpeed")
        qsk = d.bool(forKey: "Station.Qsk")
        callsFromKeyer = d.bool(forKey: "Station.CallsFromKeyer")
        getWpmUsesGaussian = d.bool(forKey: "Station.GetWpmUsesGaussian")

        activity = d.integer(forKey: "Band.Activity")
        qrn = d.bool(forKey: "Band.Qrn")
        qrm = d.bool(forKey: "Band.Qrm")
        qsb = d.bool(forKey: "Band.Qsb")
        flutter = d.bool(forKey: "Band.Flutter")
        lids = d.bool(forKey: "Band.Lids")

        webServer = d.string(forKey: "System.WebServer") ?? defaultWebServer
        submitHiScoreURL = d.string(forKey: "System.SubmitHiScoreURL") ?? ""
        postMethod = (d.string(forKey: "System.PostMethod") ?? "POST").uppercased()
        showCallsignInfo = d.bool(forKey: "System.ShowCallsignInfo") ? 1 : 0

        var vBuf = d.integer(forKey: "System.BufSize")
        if vBuf == 0 { vBuf = 3 }
        vBuf = max(1, min(5, vBuf))
        bufSize = 64 << vBuf

        monLevel = max(-60, min(0, d.integer(forKey: "Station.SelfMonVolume")))
        saveWav = d.bool(forKey: "Station.SaveWav")

        farnsworthCharRate = d.integer(forKey: "Settings.FarnsworthCharacterRate")
        wpmStepRate = max(1, min(20, d.integer(forKey: "Settings.WpmStepRate")))
        ritStepIncr = max(-500, min(500, d.integer(forKey: "Settings.RitStepIncr")))
        showCheckSection = d.integer(forKey: "Settings.ShowCheckSection")
        showExchangeSummary = d.bool(forKey: "Settings.ShowExchangeSummary")
        stationIdRate = d.integer(forKey: "Settings.StationIdRate")
        singleCallStartDelay = max(0, min(d.integer(forKey: "Settings.SingleCallStartDelay"), 2500))
        nilInstantRemove = d.bool(forKey: "Settings.NilInstantRemove")

        debugExchSettings = d.bool(forKey: "Debug.DebugExchSettings")
        debugCwDecoder = d.bool(forKey: "Debug.DebugCwDecoder")
        debugGhosting = d.bool(forKey: "Debug.DebugGhosting")
        allStationsWpmS = d.integer(forKey: "Debug.AllStationsWpmS")
        f8 = d.string(forKey: "Debug.F8") ?? ""

        // serial number ranges (startContest keeps its fixed 'Default' range)
        for (type, spec) in serialNRSettings where type != .startContest {
            let key = "Station.\(spec.key)"
            let valueStr = d.string(forKey: key) ?? (type == .midContest ? "50-500"
                : type == .endContest ? "500-5000" : "01-99")
            var s = serialNRSettings[type]!
            if let err = SerialNumberSettings.parse(valueStr, into: &s) {
                NSLog("MorseRunner: invalid serial range \(spec.key): \(err)")
            }
            serialNRSettings[type] = s
        }
        if let snr = SerialNRType(rawValue: d.integer(forKey: "Station.SerialNR")) {
            serialNR = snr
        }
    }

    /// Persist settings (port of `Ini.ToIni`).
    public static func saveToDefaults() {
        let d = UserDefaults.standard
        d.set(simContest.rawValue, forKey: "Contest.SimContest")
        d.set(defaultRunMode.rawValue, forKey: "Contest.DefaultRunMode")
        d.set(duration, forKey: "Contest.Duration")
        d.set(hiScore, forKey: "Contest.HiScore")
        d.set(compDuration, forKey: "Contest.CompetitionDuration")

        d.set(call, forKey: "Station.Call")
        for (i, exch) in userExchangeTbl.enumerated() {
            d.set(exch, forKey: "Station.Exchange.\(i)")
        }
        d.set(arrlClass, forKey: "Station.ArrlClass")
        d.set(arrlSection, forKey: "Station.ArrlSection")
        d.set(wpm, forKey: "Station.Wpm")
        d.set(maxRxWpm, forKey: "Station.CWMaxRxSpeed")
        d.set(minRxWpm, forKey: "Station.CWMinRxSpeed")
        d.set(qsk, forKey: "Station.Qsk")
        d.set(callsFromKeyer, forKey: "Station.CallsFromKeyer")
        d.set(getWpmUsesGaussian, forKey: "Station.GetWpmUsesGaussian")
        d.set(serialNR.rawValue, forKey: "Station.SerialNR")
        if let custom = serialNRSettings[.customRange] {
            d.set(custom.rangeStr, forKey: "Station.\(custom.key)")
        }
        d.set(monLevel, forKey: "Station.SelfMonVolume")
        d.set(saveWav, forKey: "Station.SaveWav")

        d.set(activity, forKey: "Band.Activity")
        d.set(qrn, forKey: "Band.Qrn")
        d.set(qrm, forKey: "Band.Qrm")
        d.set(qsb, forKey: "Band.Qsb")
        d.set(flutter, forKey: "Band.Flutter")
        d.set(lids, forKey: "Band.Lids")

        d.set(webServer, forKey: "System.WebServer")
        d.set(submitHiScoreURL, forKey: "System.SubmitHiScoreURL")
        d.set(postMethod, forKey: "System.PostMethod")
        d.set(showCallsignInfo != 0, forKey: "System.ShowCallsignInfo")

        d.set(farnsworthCharRate, forKey: "Settings.FarnsworthCharacterRate")
        d.set(wpmStepRate, forKey: "Settings.WpmStepRate")
        d.set(ritStepIncr, forKey: "Settings.RitStepIncr")
        d.set(showCheckSection, forKey: "Settings.ShowCheckSection")
        d.set(showExchangeSummary, forKey: "Settings.ShowExchangeSummary")
        d.set(stationIdRate, forKey: "Settings.StationIdRate")
        d.set(singleCallStartDelay, forKey: "Settings.SingleCallStartDelay")
        d.set(nilInstantRemove, forKey: "Settings.NilInstantRemove")

        d.set(debugExchSettings, forKey: "Debug.DebugExchSettings")
        d.set(debugCwDecoder, forKey: "Debug.DebugCwDecoder")
        d.set(debugGhosting, forKey: "Debug.DebugGhosting")
        d.set(allStationsWpmS, forKey: "Debug.AllStationsWpmS")
        d.set(f8, forKey: "Debug.F8")
    }

    /// Port of `IsNum`.
    public static func isNum(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isNumber }
    }

    /// Port of `FindContestByName`.
    public static func findContestByName(_ name: String) -> SimContest? {
        for (idx, def) in contestDefinitions.enumerated()
        where def.name.compare(name, options: .caseInsensitive) == .orderedSame {
            return SimContest(rawValue: idx)
        }
        return nil
    }

    /// The contest's exchange default message for its user exchange field.
    public static func userExchange(for contest: SimContest) -> String {
        userExchangeTbl[contest.rawValue]
    }
}

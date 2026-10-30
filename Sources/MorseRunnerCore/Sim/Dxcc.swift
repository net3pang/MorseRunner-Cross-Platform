// Port of DXCC.pas — the ARRL DXCC entity table (DXCC.LIST).

import Foundation

/// One DXCC record (Delphi `TDXCCRec`).
final class DxccRec {
    let prefixReg: String
    let entity: String
    let continent: String
    let itu: String
    let cq: String

    init(prefixReg: String, entity: String, continent: String, itu: String, cq: String) {
        self.prefixReg = prefixReg
        self.entity = entity
        self.continent = continent
        self.itu = itu
        self.cq = cq
    }

    var displayString: String {
        if entity == "United States of America" {
            return "\(continent)/United States;  ITU Zone: \(itu);  CQ Zone: \(cq)"
        }
        return "\(continent)/\(entity);  ITU Zone: \(itu);  CQ Zone: \(cq)"
    }
}

/// DXCC list with cached, compiled prefix regexes (port of `TDXCC`).
final class Dxcc {
    nonisolated(unsafe) static let shared = Dxcc()

    private var dxccList: [DxccRec] = []
    private var regexCache: [NSRegularExpression?] = []

    init() {
        loadDxccList()
    }

    private func loadDxccList() {
        guard let text = DataFiles.loadString("DXCC.LIST") else {
            NSLog("MorseRunner: DXCC.LIST not found; DXCC lookups disabled")
            return
        }
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix("#") { continue }
            let fields = line.components(separatedBy: ";")
            if fields.count == 7 {
                // some expressions are ignored because they mask other entities
                if fields[1].hasPrefix("!ignore") { continue }
                dxccList.append(DxccRec(
                    prefixReg: fields[1],
                    entity: fields[2],
                    continent: fields[3],
                    itu: fields[4],
                    cq: fields[5]))
            }
        }
        regexCache = [NSRegularExpression?](repeating: nil, count: dxccList.count)
    }

    /// Walk the list in reverse (longest/most-specific first); first match wins.
    private func searchPrefix(_ callPrefix: String) -> Int? {
        guard !callPrefix.isEmpty else { return nil }
        let nsRange = NSRange(callPrefix.startIndex..., in: callPrefix)
        for i in stride(from: dxccList.count - 1, through: 0, by: -1) {
            if regexCache[i] == nil {
                regexCache[i] = try? NSRegularExpression(pattern: "^(" + dxccList[i].prefixReg + ")")
            }
            if let regex = regexCache[i], regex.firstMatch(in: callPrefix, range: nsRange) != nil {
                return i
            }
        }
        return nil
    }

    /// Find the DXCC record for a callsign (Delphi `FindRec`).
    func findRec(_ callsign: String) -> DxccRec? {
        // Use the full call when extracting the prefix (e.g. F6/W7SST -> 'F6').
        // Keep trailing letters so longest-match-first works (e.g. RC2F).
        var sP = CallsignUtils.extractPrefix(callsign, deleteTrailingLetters: false)

        // KG4 special case: 2x1 and 2x3 are US; 2x2 is Guantanamo Bay.
        if sP.hasPrefix("KG4") && !sP.hasPrefix("KG44") && (sP.count == 6 || sP.count == 4) {
            sP = "K"
        }

        // Antarctica special case: CE9/ or KC4/ prefixes and KC4(AA|US)[A-Z]
        if (sP.count == 3 && (sP == "CE9" || sP == "KC4"))
            || (sP.count == 6 && (sP.hasPrefix("KC4AA") || sP.hasPrefix("KC4US"))) {
            sP = "CE9KC4"
        }

        guard let index = searchPrefix(sP) else { return nil }
        return dxccList[index]
    }

    /// Display only the entered callsign's prefix, including its district digit
    /// (e.g. N1MM -> N1), rather than all prefixes assigned to its DXCC entity.
    func displayPrefix(for callsign: String) -> String {
        let prefix = CallsignUtils.extractPrefix(callsign)
        return prefix.isEmpty ? "Unknown" : prefix
    }

    /// Status-bar info string (Delphi `GetStationInfo`/`Search`).
    func stationInfo(_ callsign: String) -> String {
        guard let rec = findRec(callsign) else { return "Unknown" }
        return displayPrefix(for: callsign) + ":  " + rec.displayString
    }
}

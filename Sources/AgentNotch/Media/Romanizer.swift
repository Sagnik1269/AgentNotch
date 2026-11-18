import Foundation

/// Writes lyrics in Latin letters the way people actually type them ("tum hi ho", not "तुम ही हो"
/// or the dictionary-style "tuma hī hō"). This is transliteration, not translation.
///
/// Devanagari (Hindi and related) and Gurmukhi (Punjabi) get a Hinglish-style converter with
/// schwa deletion; any other non-Latin script falls back to the system transliterator.
enum Romanizer {
    /// True when a meaningful share of the letters are not Latin.
    static func needsRomanizing(_ text: String) -> Bool {
        var latin = 0, other = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if scalar.isASCII || (0x00C0...0x024F).contains(scalar.value) { latin += 1 } else { other += 1 }
        }
        return other > 0 && Double(other) / Double(latin + other) > 0.3
    }

    static func romanize(_ text: String) -> String {
        guard needsRomanizing(text) else { return text }
        var s = text
        if s.unicodeScalars.contains(where: isGurmukhi) { s = gurmukhiToDevanagari(s) }
        if s.unicodeScalars.contains(where: isDevanagari) { s = devanagariToLatin(s) }
        if needsRomanizing(s) {
            // Korean, Bengali, Tamil, Cyrillic, … : the system's transliteration, without accent marks.
            s = s.applyingTransform(.toLatin, reverse: false) ?? s
            s = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        }
        return capitalizeFirst(s)
    }

    // MARK: - Script helpers

    private static func isDevanagari(_ u: Unicode.Scalar) -> Bool { (0x0900...0x097F).contains(u.value) }
    private static func isGurmukhi(_ u: Unicode.Scalar) -> Bool { (0x0A00...0x0A7F).contains(u.value) }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: \.isLetter) else { return s }
        return s.replacingCharacters(in: i...i, with: s[i].uppercased())
    }

    /// Gurmukhi → Devanagari via the system, after expanding the addak (ੱ, "double the next
    /// consonant"), which the system transform drops.
    private static func gurmukhiToDevanagari(_ s: String) -> String {
        var scalars: [Unicode.Scalar] = []
        var pendingAddak = false
        for u in s.unicodeScalars {
            if u.value == 0x0A71 { pendingAddak = true; continue }
            if pendingAddak, (0x0A15...0x0A39).contains(u.value) || (0x0A59...0x0A5E).contains(u.value) {
                scalars.append(u)
                scalars.append(Unicode.Scalar(0x0A4D)!)   // virama
            }
            pendingAddak = false
            scalars.append(u)
        }
        let expanded = String(String.UnicodeScalarView(scalars))
        return expanded.applyingTransform(StringTransform("Gurmukhi-Devanagari"), reverse: false) ?? expanded
    }

    // MARK: - Devanagari → Hinglish

    /// Common words whose everyday spelling doesn't follow from the letters.
    private static let words: [String: String] = [
        "हम": "hum", "हमें": "humein", "हमारा": "humara", "हमारी": "humari", "हमारे": "humare",
        "मैं": "main", "में": "mein", "मैंने": "maine", "है": "hai", "हैं": "hain",
        "नहीं": "nahi", "नही": "nahi", "हाँ": "haan", "हां": "haan", "माँ": "maa", "मां": "maa",
        "यहाँ": "yahan", "यहां": "yahan", "वहाँ": "wahan", "वहां": "wahan", "कहाँ": "kahan",
        "कहां": "kahan", "जहाँ": "jahan", "जहां": "jahan", "वो": "woh", "वह": "woh", "ये": "ye",
        "यह": "yeh", "क्यों": "kyun", "क्यूँ": "kyun", "क्यूं": "kyun", "यूँ": "yun", "यूं": "yun",
        "तू": "tu", "और": "aur", "कि": "ki", "भी": "bhi",
    ]

    private enum Vowel { case a, aa, i, ii, u, uu, ri, e, ai, o, au }

    private struct Unit {
        var consonant: String?      // nil for an independent vowel
        var vowel: Vowel?           // nil = halant (consonant cluster)
        var inherent = false        // vowel is the implicit "a"
        var deleted = false         // schwa dropped
        var nasal = false
        var visarga = false

        var soundsVowel: Bool { vowel != nil && !deleted }
    }

    private static let consonants: [UInt32: String] = [
        0x0915: "k", 0x0916: "kh", 0x0917: "g", 0x0918: "gh", 0x0919: "n",
        0x091A: "ch", 0x091B: "chh", 0x091C: "j", 0x091D: "jh", 0x091E: "n",
        0x091F: "t", 0x0920: "th", 0x0921: "d", 0x0922: "dh", 0x0923: "n",
        0x0924: "t", 0x0925: "th", 0x0926: "d", 0x0927: "dh", 0x0928: "n", 0x0929: "n",
        0x092A: "p", 0x092B: "ph", 0x092C: "b", 0x092D: "bh", 0x092E: "m",
        0x092F: "y", 0x0930: "r", 0x0931: "r", 0x0932: "l", 0x0933: "l", 0x0934: "l", 0x0935: "v",
        0x0936: "sh", 0x0937: "sh", 0x0938: "s", 0x0939: "h",
        // Precomposed nukta letters.
        0x0958: "q", 0x0959: "kh", 0x095A: "gh", 0x095B: "z", 0x095C: "d", 0x095D: "rh", 0x095E: "f", 0x095F: "y",
    ]
    /// Base consonant + nukta (़).
    private static let nukta: [String: String] = ["k": "q", "kh": "kh", "g": "gh", "j": "z", "d": "d", "dh": "rh", "ph": "f", "y": "y"]

    private static let matras: [UInt32: Vowel] = [
        0x093E: .aa, 0x093F: .i, 0x0940: .ii, 0x0941: .u, 0x0942: .uu, 0x0943: .ri,
        0x0945: .e, 0x0946: .e, 0x0947: .e, 0x0948: .ai, 0x0949: .o, 0x094A: .o, 0x094B: .o, 0x094C: .au,
    ]
    private static let independent: [UInt32: Vowel] = [
        0x0905: .a, 0x0906: .aa, 0x0907: .i, 0x0908: .ii, 0x0909: .u, 0x090A: .uu, 0x090B: .ri,
        0x090D: .e, 0x090E: .e, 0x090F: .e, 0x0910: .ai, 0x0911: .o, 0x0912: .o, 0x0913: .o, 0x0914: .au,
    ]

    private static func devanagariToLatin(_ text: String) -> String {
        var out = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            out += words[word] ?? romanizeWord(word)
            word = ""
        }
        for ch in text {
            if ch.unicodeScalars.contains(where: isDevanagari) && !"।॥".contains(ch) {
                word.append(ch)
            } else {
                flush()
                out.append(ch == "।" || ch == "॥" ? "," : ch)
            }
        }
        flush()
        return out.replacingOccurrences(of: #",\s*$"#, with: "", options: .regularExpression)
    }

    private static func romanizeWord(_ word: String) -> String {
        var units: [Unit] = []
        var digits = ""
        for u in word.unicodeScalars {
            let v = u.value
            if let c = consonants[v] {
                units.append(Unit(consonant: c, vowel: .a, inherent: true))
            } else if v == 0x093C, let last = units.indices.last, let c = units[last].consonant {
                units[last].consonant = nukta[c] ?? c
            } else if let m = matras[v], let last = units.indices.last, units[last].consonant != nil {
                units[last].vowel = m
                units[last].inherent = false
            } else if v == 0x094D, let last = units.indices.last {
                units[last].vowel = nil
                units[last].inherent = false
            } else if let iv = independent[v] {
                units.append(Unit(consonant: nil, vowel: iv))
            } else if v == 0x0901 || v == 0x0902 || v == 0x0A70, let last = units.indices.last {
                units[last].nasal = true
            } else if v == 0x0903, let last = units.indices.last {
                units[last].visarga = true
            } else if v == 0x0950 {
                units.append(Unit(consonant: nil, vowel: .o))
                units.append(Unit(consonant: "m", vowel: nil))
            } else if (0x0966...0x096F).contains(v) {
                digits.append(Character(String(v - 0x0966)))
            }
        }
        if units.isEmpty { return digits }

        // Schwa deletion. Word-final "a" is silent (दिल → dil) unless the word is one letter.
        if units.count > 1, let last = units.indices.last, units[last].inherent, !units[last].nasal {
            units[last].deleted = true
        }
        // Medial: in vowel-consonant-[a]-consonant-vowel, the "a" is silent (समझना → samajhna).
        // Scan right to left so earlier decisions see later deletions.
        if units.count > 2 {
            for i in stride(from: units.count - 2, through: 1, by: -1) {
                guard units[i].inherent, !units[i].nasal, units[i].consonant != nil else { continue }
                let left = units[i - 1], right = units[i + 1]
                if left.soundsVowel, right.consonant != nil, right.soundsVowel {
                    units[i].deleted = true
                }
            }
        }

        var s = ""
        for (i, unit) in units.enumerated() {
            let isLast = i == units.count - 1
            s += unit.consonant ?? ""
            if let vowel = unit.vowel, !unit.deleted {
                let beforeVowel = !isLast && units[i + 1].consonant == nil
                s += beforeVowel && (vowel == .i || vowel == .ii) ? "iy" : spell(vowel, isLast: isLast, nasal: unit.nasal)
                if unit.nasal && !isLast {
                    let next = units[i + 1].consonant ?? ""
                    s += ["p", "ph", "b", "bh", "m"].contains(next) ? "m" : "n"
                }
            } else if unit.nasal {
                s += "n"
            }
            if unit.visarga { s += "h" }
        }
        return s + digits
    }

    /// Hinglish vowel spelling: long vowels are doubled inside a word but single at the end
    /// (mera, kabhi, tu), and a final nasal reads as "n" (hoon, nahin, mein, gallaan).
    private static func spell(_ v: Vowel, isLast: Bool, nasal: Bool) -> String {
        let finalNasal = isLast && nasal
        switch v {
        case .a: return "a"
        case .aa: return finalNasal ? "aan" : (isLast ? "a" : "aa")
        case .i: return finalNasal ? "in" : "i"
        case .ii: return finalNasal ? "in" : (isLast ? "i" : "ee")
        case .u: return finalNasal ? "un" : "u"
        case .uu: return finalNasal ? "oon" : (isLast ? "u" : "oo")
        case .ri: return "ri"
        case .e: return finalNasal ? "ein" : "e"
        case .ai: return finalNasal ? "ain" : "ai"
        case .o: return finalNasal ? "on" : "o"
        case .au: return finalNasal ? "aun" : "au"
        }
    }
}

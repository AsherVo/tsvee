import Foundation

/// Series continuation for the fill handle (Google-Sheets-style autofill).
///
/// Given the source values along the drag axis, produces the next `count`
/// values:
///  - single value            → copied ("hp" → hp, hp, …)
///  - integer run             → arithmetic continuation (1, 3 → 5, 7, …)
///  - zero-padded integers    → padded continuation (007, 008 → 009)
///  - decimal run             → exact Decimal continuation (0.5, 1.0 → 1.5)
///  - text + trailing integer → prefix kept, number continued
///                              (slime_01, slime_02 → slime_03)
///  - anything else           → the pattern repeats cyclically
enum AutofillSeries {

    static func extend(_ source: [String], count: Int) -> [String] {
        guard count > 0, !source.isEmpty else { return [] }
        if source.count == 1 {
            return Array(repeating: source[0], count: count)
        }
        if let next = integerContinuation(source, count: count) { return next }
        if let next = paddedIntegerContinuation(source, count: count) { return next }
        if let next = decimalContinuation(source, count: count) { return next }
        if let next = trailingIntegerContinuation(source, count: count) { return next }
        return (0..<count).map { source[$0 % source.count] }
    }

    // MARK: - Integer runs ("1", "3", "5" …)

    private static func integerContinuation(_ source: [String], count: Int) -> [String]? {
        var values: [Int] = []
        for s in source {
            // Require canonical formatting so "007" takes the padded path.
            guard let v = Int(s), String(v) == s else { return nil }
            values.append(v)
        }
        guard let step = constantStep(values) else { return nil }
        return (1...count).map { String(values[values.count - 1] + step * $0) }
    }

    // MARK: - Zero-padded integers ("007", "008" …)

    private static func paddedIntegerContinuation(_ source: [String], count: Int) -> [String]? {
        var values: [Int] = []
        for s in source {
            guard s.allSatisfy(\.isNumber), let v = Int(s) else { return nil }
            values.append(v)
        }
        guard let step = constantStep(values) else { return nil }
        let width = source[source.count - 1].count
        return (1...count).map { pad(values[values.count - 1] + step * $0, width: width) }
    }

    // MARK: - Decimal runs ("0.5", "1.0" …)

    private static func decimalContinuation(_ source: [String], count: Int) -> [String]? {
        guard source.contains(where: { $0.contains(".") }) else { return nil }
        var values: [Decimal] = []
        for s in source {
            guard let v = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            values.append(v)
        }
        let step = values[1] - values[0]
        for i in 1..<values.count where values[i] - values[i - 1] != step { return nil }
        var last = values[values.count - 1]
        return (0..<count).map { _ in
            last += step
            return NSDecimalNumber(decimal: last).stringValue
        }
    }

    // MARK: - Text with a trailing integer ("slime_01" …)

    private static func trailingIntegerContinuation(_ source: [String], count: Int) -> [String]? {
        var prefixes: [Substring] = []
        var digitParts: [Substring] = []
        for s in source {
            let digits = s.suffix(while: \.isNumber)
            guard !digits.isEmpty, digits.count < 19 else { return nil }
            prefixes.append(s.dropLast(digits.count))
            digitParts.append(digits)
        }
        guard prefixes.dropFirst().allSatisfy({ $0 == prefixes[0] }) else { return nil }
        let values = digitParts.map { Int($0)! }
        guard let step = constantStep(values) else { return nil }
        let width = digitParts[digitParts.count - 1].count
        return (1...count).map { prefixes[0] + pad(values[values.count - 1] + step * $0, width: width) }
    }

    // MARK: - Helpers

    private static func constantStep(_ values: [Int]) -> Int? {
        guard values.count >= 2 else { return nil }
        let step = values[1] - values[0]
        for i in 1..<values.count where values[i] - values[i - 1] != step { return nil }
        return step
    }

    private static func pad(_ value: Int, width: Int) -> String {
        guard value >= 0 else { return String(value) }
        let raw = String(value)
        return raw.count >= width ? raw : String(repeating: "0", count: width - raw.count) + raw
    }
}

private extension String {
    func suffix(while predicate: (Character) -> Bool) -> Substring {
        var start = endIndex
        while start > startIndex {
            let prev = index(before: start)
            guard predicate(self[prev]) else { break }
            start = prev
        }
        return self[start...]
    }
}

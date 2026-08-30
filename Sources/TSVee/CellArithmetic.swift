import AppKit

/// Arithmetic over a selection: "Adjust Values" in the context menu applies
/// one operation to every number in the selected cells and leaves everything
/// else exactly as it was.
///
/// Values are read and written as text, so the rules are about spelling as
/// much as about maths:
///  - Only a cleanly written number counts ("12", "-0.5", ".5"). Anything with
///    other characters in it ("12 hp", "1,000", "$3") is not a number here and
///    is passed over — a sheet like this holds plenty of prose.
///  - The result keeps the cell's shape: "007" stays three digits wide, "1.50"
///    keeps its two decimal places.
///  - Exact decimal maths throughout (`Decimal`, like ``AutofillSeries``), so
///    money doesn't drift. Only division can fail to terminate; it rounds.
enum CellArithmetic {

    enum Operation: String, CaseIterable {
        case add, subtract, multiply, divide

        var menuTitle: String {
            switch self {
            case .add: return "Add…"
            case .subtract: return "Subtract…"
            case .multiply: return "Multiply By…"
            case .divide: return "Divide By…"
            }
        }

        /// What the undo menu calls the change afterwards.
        var actionName: String {
            switch self {
            case .add: return "Add to Cells"
            case .subtract: return "Subtract from Cells"
            case .multiply: return "Multiply Cells"
            case .divide: return "Divide Cells"
            }
        }

        fileprivate var promptTitle: String {
            switch self {
            case .add: return "Add to Selected Cells"
            case .subtract: return "Subtract from Selected Cells"
            case .multiply: return "Multiply Selected Cells By"
            case .divide: return "Divide Selected Cells By"
            }
        }
    }

    /// Fraction digits a repeating quotient is cut off at — enough to keep a
    /// third of something useful, few enough that the cell stays readable.
    private static let divisionScale = 10

    private static let posix = Locale(identifier: "en_US_POSIX")

    // MARK: - Reading numbers

    /// The number a cell holds, or nil when it holds anything else. Strict on
    /// purpose: `Decimal(string:)` alone would read "12 hp" as 12 and quietly
    /// turn a note into a number.
    static func number(_ value: String) -> Decimal? {
        guard isPlainNumber(value) else { return nil }
        return Decimal(string: value, locale: posix)
    }

    /// Optional sign, digits, at most one decimal point, at least one digit,
    /// nothing else — and short enough for `Decimal` to hold every digit it
    /// was given (38), so no value is silently rounded on the way in.
    private static func isPlainNumber(_ value: String) -> Bool {
        var body = Substring(value)
        if body.first == "-" || body.first == "+" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, body.count <= 30 else { return false }
        guard parts.contains(where: { !$0.isEmpty }) else { return false }
        return parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    // MARK: - Applying an operation

    /// The cell's new content, or nil when the cell isn't a number (or the
    /// operation can't be done) — so callers can leave those cells untouched.
    static func apply(_ operation: Operation, operand: Decimal, to value: String) -> String? {
        guard let current = number(value) else { return nil }
        let result: Decimal
        switch operation {
        case .add:
            result = current + operand
        case .subtract:
            result = current - operand
        case .multiply:
            result = current * operand
        case .divide:
            guard operand != 0 else { return nil }
            var quotient = current / operand
            var rounded = Decimal()
            NSDecimalRound(&rounded, &quotient, divisionScale, .plain)
            result = rounded
        }
        return format(result, like: value)
    }

    /// Writes the result the way the cell was written: a zero-padded count
    /// keeps its width, a decimal keeps at least as many places as it had.
    private static func format(_ result: Decimal, like original: String) -> String {
        let text = NSDecimalNumber(decimal: result).stringValue
        if isZeroPadded(original), text.allSatisfy({ $0.isASCII && $0.isNumber }),
           text.count < original.count {
            return String(repeating: "0", count: original.count - text.count) + text
        }
        let wanted = fractionDigits(of: original)
        let have = fractionDigits(of: text)
        guard wanted > have else { return text }
        return text + (have == 0 ? "." : "") + String(repeating: "0", count: wanted - have)
    }

    /// "007" — a count written to a fixed width, where dropping the padding
    /// would look like a different value.
    private static func isZeroPadded(_ value: String) -> Bool {
        value.count > 1 && value.hasPrefix("0")
            && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func fractionDigits(of value: String) -> Int {
        guard let dot = value.firstIndex(of: ".") else { return 0 }
        return value.distance(from: value.index(after: dot), to: value.endIndex)
    }

    // MARK: - The prompt

    /// Last operand per operation, so adjusting one column and then the next
    /// by the same amount is two clicks and a Return.
    private static var lastOperand: [Operation: String] = [:]

    /// Asks for the number to apply. nil means the user cancelled; the prompt
    /// re-asks rather than accepting something it can't use.
    static func runPrompt(operation: Operation, cellCount: Int) -> Decimal? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = operation == .multiply || operation == .divide ? "2" : "1"
        field.stringValue = lastOperand[operation] ?? ""
        field.alignment = .right

        while true {
            let alert = NSAlert()
            alert.messageText = operation.promptTitle
            alert.informativeText = cellCount == 1
                ? "One selected cell holds a number. Cells that don't are left alone."
                : "\(cellCount) selected cells hold numbers. Cells that don't are left alone."
            alert.addButton(withTitle: "Apply")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }

            let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
            if let operand = number(typed), !(operation == .divide && operand == 0) {
                lastOperand[operation] = typed
                return operand
            }
            NSSound.beep()
            field.selectText(nil)
        }
    }
}

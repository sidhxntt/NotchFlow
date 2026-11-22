import AppKit
import SwiftUI

/// A pocket calculator in the notch: type or tap an expression on the left and
/// the answer updates as you go; Return (or =) commits it to a short tape you can
/// tap to reuse. Evaluation is the same exact parser the assistant's `calculate`
/// tool uses, so the notch never disagrees with itself about what 18% of 240 is.
struct CalculatorOverlayView: View {
    let close: () -> Void

    @State private var expression = ""
    @State private var history = CalculatorHistory.load()
    @State private var commitError: String?
    @State private var copied = false
    @FocusState private var fieldFocused: Bool
    @AppStorage(CalculatorPreferences.showsKeypadKey) private var showsKeypad = true
    @AppStorage(CalculatorPreferences.keepsTapeKey) private var keepsTape = true
    @AppStorage(CalculatorPreferences.precisionKey) private var precision = CalculatorPreferences.automaticPrecision

    private static let keypad: [[CalculatorKey]] = [
        [.digit(7), .digit(8), .digit(9), .divide, .clear],
        [.digit(4), .digit(5), .digit(6), .multiply, .backspace],
        [.digit(1), .digit(2), .digit(3), .subtract, .parenthesis],
        [.digit(0), .decimal, .percent, .add],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            headerRow
            HStack(alignment: .top, spacing: 12) {
                displayColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsKeypad {
                    keypadGrid
                        .frame(width: 196)
                        .transition(.opacity)
                }
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onAppear { fieldFocused = true }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Label("Calculator", systemImage: "plus.forwardslash.minus")
                .font(.sf(13, weight: .bold)).foregroundStyle(Tokens.text1)
            Spacer()
            if keepsTape && !history.records.isEmpty {
                Button("Clear tape") {
                    history.clear()
                    history.save()
                }
                .buttonStyle(.plain)
                .font(.sf(10, weight: .semibold))
                .foregroundStyle(Tokens.text3)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.sf(10, weight: .bold))
                    .frame(width: 25, height: 25)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(Tokens.text3)
            .accessibilityLabel("Close Calculator")
        }
    }

    // MARK: - Display and tape

    private var displayColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .trailing, spacing: 3) {
                TextField("", text: $expression, prompt: Text("2,400 × 18%").foregroundStyle(Tokens.placeholder))
                    .textFieldStyle(.plain)
                    .font(.sf(13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Tokens.text2)
                    .multilineTextAlignment(.trailing)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onChange(of: expression) { _, _ in commitError = nil }

                HStack(spacing: 6) {
                    if let commitError {
                        Text(commitError)
                            .font(.sf(10.5, weight: .medium))
                            .foregroundStyle(Tokens.danger)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Text(liveResult.map { "= \($0)" } ?? " ")
                        .font(.sf(20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                    if liveResult != nil {
                        Button(action: copyResult) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.sf(10, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.08), in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(copied ? Tokens.success : Tokens.text3)
                        .help("Copy result")
                        .accessibilityLabel("Copy result")
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !keepsTape {
                Text("Press Return to tidy the sum into its answer. The tape is off in Settings → Utilities.")
                    .font(.sf(10.5, weight: .regular))
                    .foregroundStyle(Tokens.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            } else if history.records.isEmpty {
                Text("Press Return or = to keep a result here. Tap one to reuse it.")
                    .font(.sf(10.5, weight: .regular))
                    .foregroundStyle(Tokens.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            } else {
                VStack(spacing: 4) {
                    ForEach(history.records.prefix(3)) { record in
                        tapeRow(record)
                    }
                }
            }
        }
    }

    private func tapeRow(_ record: CalculationRecord) -> some View {
        Button {
            expression = record.result
            fieldFocused = true
        } label: {
            HStack(spacing: 6) {
                Text(record.expression)
                    .font(.sf(10.5, weight: .regular).monospacedDigit())
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                Text("= \(record.result)")
                    .font(.sf(11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
        .help("Use \(record.result)")
    }

    // MARK: - Keypad

    private var keypadGrid: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(Self.keypad.indices, id: \.self) { row in
                GridRow {
                    ForEach(Self.keypad[row], id: \.self) { key in
                        keyButton(key)
                    }
                    if row == Self.keypad.count - 1 {
                        equalsButton
                    }
                }
            }
        }
    }

    private func keyButton(_ key: CalculatorKey) -> some View {
        Button {
            expression = CalculatorInput.apply(key, to: expression)
        } label: {
            keyLabel(key.label, symbol: key == .backspace ? "delete.left" : nil)
                .foregroundStyle(keyInk(key))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isDigit(key) ? 0.07 : 0.11)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName(key))
    }

    private var equalsButton: some View {
        Button(action: commit) {
            keyLabel("=", symbol: nil)
                .foregroundStyle(Color.white)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Tokens.accent.opacity(0.75)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Equals")
    }

    private func keyLabel(_ text: String, symbol: String?) -> some View {
        Group {
            if let symbol {
                Image(systemName: symbol).font(.sf(11, weight: .semibold))
            } else {
                Text(text).font(.sf(12.5, weight: .semibold).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func isDigit(_ key: CalculatorKey) -> Bool {
        if case .digit = key { return true }
        return key == .decimal
    }

    private func keyInk(_ key: CalculatorKey) -> Color {
        switch key {
        case .clear: Tokens.danger
        case .add, .subtract, .multiply, .divide, .percent, .parenthesis: Tokens.accent
        default: Tokens.text1
        }
    }

    private func accessibilityName(_ key: CalculatorKey) -> String {
        switch key {
        case .digit(let d): String(d)
        case .decimal: "Decimal point"
        case .add: "Plus"
        case .subtract: "Minus"
        case .multiply: "Times"
        case .divide: "Divided by"
        case .percent: "Percent"
        case .parenthesis: "Parenthesis"
        case .backspace: "Delete"
        case .clear: "Clear"
        }
    }

    // MARK: - Evaluation

    /// The answer so far, or nil while the expression is empty or still
    /// half-typed ("12 ×") — an unfinished sum shows nothing rather than an error.
    private var liveResult: String? {
        try? evaluate(expression)
    }

    private func evaluate(_ text: String) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var parser = ArithmeticParser(trimmed)
        let value = try parser.evaluate()
        return CalculatorPreferences.format(value, places: precision, automatic: CalculateTool.format)
    }

    private func commit() {
        do {
            guard let result = try evaluate(expression) else { return }
            // A bare number isn't a calculation worth keeping ("432 = 432").
            if keepsTape && expression.trimmingCharacters(in: .whitespaces) != result {
                history.record(expression: expression, result: result)
                history.save()
            }
            expression = result
        } catch let error as ArithmeticParser.ParseError {
            commitError = error.message.prefix(1).uppercased() + error.message.dropFirst()
        } catch {
            commitError = "That isn't a sum I can work out."
        }
        fieldFocused = true
    }

    private func copyResult() {
        guard let result = liveResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

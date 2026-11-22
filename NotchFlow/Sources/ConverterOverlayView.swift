import AppKit
import SwiftUI

/// Unit conversion without leaving what you're doing: pick a family, type a
/// value, read the answer. Currency uses the European Central Bank's daily
/// reference rates, fetched at most every few hours and cached so it keeps
/// working offline; every other family is fixed arithmetic computed locally.
/// The value field accepts a sum too ("3 × 12"), evaluated by the same parser
/// as the Calculator. Which families appear is chosen in Settings → Utilities.
struct ConverterOverlayView: View {
    let close: () -> Void

    @State private var selection = ConverterSelection.load(visible: ConverterCategoryVisibility.visible())
    @ObservedObject private var currency = CurrencyRateStore.shared
    @AppStorage(ConverterCategoryVisibility.hiddenKey) private var hiddenCategories = ""
    @State private var input = "1"
    @State private var copied = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            categoryStrip
            conversionRow
            footnote
        }
        .padding(11)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onAppear {
            fieldFocused = true
            refreshRatesIfNeeded()
        }
        .onChange(of: selection) { _, next in
            next.save()
            refreshRatesIfNeeded()
        }
        .onChange(of: hiddenCategories) { _, raw in
            // Settings hid the family that's open: move to the first one left.
            let visible = ConverterCategoryVisibility.visible(hiddenRaw: raw)
            if !visible.contains(selection.category), let first = visible.first {
                selection.select(first)
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Label("Converter", systemImage: "arrow.left.arrow.right")
                .font(.sf(13, weight: .bold)).foregroundStyle(Tokens.text1)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.sf(10, weight: .bold))
                    .frame(width: 25, height: 25)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(Tokens.text3)
            .accessibilityLabel("Close Converter")
        }
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(ConverterCategoryVisibility.visible(hiddenRaw: hiddenCategories)) { category in
                    categoryChip(category)
                }
            }
        }
    }

    private func categoryChip(_ category: ConversionCategory) -> some View {
        let selected = category == selection.category
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { selection.select(category) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: category.symbolName).font(.sf(9.5, weight: .semibold))
                Text(category.title).font(.sf(10.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? Tokens.text1 : Tokens.text3)
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : 0.05)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0.18 : 0), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Conversion

    private var conversionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("", text: $input, prompt: Text("Value").foregroundStyle(Tokens.placeholder))
                    .textFieldStyle(.plain)
                    .font(.sf(17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Tokens.text1)
                    .focused($fieldFocused)
                unitMenu(selection.from) { selection.from = $0 }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                withAnimation(.easeOut(duration: 0.16)) { swapUnits() }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.sf(11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.accent)
            .help("Swap units")
            .accessibilityLabel("Swap units")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(resultText ?? "—")
                        .font(.sf(17, weight: .semibold).monospacedDigit())
                        .foregroundStyle(resultText == nil ? Tokens.text3 : Tokens.text1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    if resultText != nil {
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
                unitMenu(selection.to) { selection.to = $0 }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func unitMenu(_ current: ConversionUnit, choose: @escaping (ConversionUnit) -> Void) -> some View {
        Menu {
            ForEach(selection.category.units) { unit in
                Button {
                    choose(unit)
                } label: {
                    if unit == current {
                        Label("\(unit.name) (\(unit.symbol))", systemImage: "checkmark")
                    } else {
                        Text("\(unit.name) (\(unit.symbol))")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(current.name).font(.sf(10.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.sf(7.5, weight: .bold))
            }
            .foregroundStyle(Tokens.text3)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder
    private var footnote: some View {
        if selection.category.usesLiveRates {
            currencyFootnote
        } else {
            let rate = UnitConverter.convert(1, from: selection.from, to: selection.to)
            footnoteText("1 \(selection.from.symbol) = \(UnitConverter.format(rate)) \(selection.to.symbol)")
        }
    }

    private var currencyFootnote: some View {
        HStack(spacing: 6) {
            if let rates = currency.rates,
               let rate = rates.convert(1, from: selection.from.symbol, to: selection.to.symbol) {
                footnoteText("1 \(selection.from.symbol) = \(UnitConverter.formatCurrency(rate)) \(selection.to.symbol) · \(CurrencyRates.sourceName) rates, \(rates.publishedLabel)")
            } else if currency.state == .loading {
                footnoteText("Fetching today’s rates…")
            } else {
                footnoteText("Rates need a connection the first time. After that they work offline.")
            }
            Spacer(minLength: 4)
            if currency.state == .loading {
                ProgressView().controlSize(.mini)
            } else if currency.state == .failed || currency.rates == nil {
                Button("Retry") { Task { await currency.refresh() } }
                    .buttonStyle(.plain)
                    .font(.sf(10, weight: .semibold))
                    .foregroundStyle(Tokens.accent)
            }
        }
    }

    private func footnoteText(_ text: String) -> some View {
        Text(text)
            .font(.sf(10, weight: .medium).monospacedDigit())
            .foregroundStyle(Tokens.text3)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 2)
    }

    private func refreshRatesIfNeeded() {
        guard selection.category.usesLiveRates else { return }
        Task { await currency.refreshIfNeeded() }
    }

    // MARK: - Logic

    /// The typed value as a number: a plain figure first (fast, lenient about
    /// grouping commas), then a sum through the Calculator's parser.
    private var inputValue: Double? {
        if let plain = UnitConverter.parse(input) { return plain }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var parser = ArithmeticParser(trimmed)
        guard let value = try? parser.evaluate(), value.isFinite else { return nil }
        return value
    }

    private var resultText: String? {
        guard let value = inputValue else { return nil }
        if selection.category.usesLiveRates {
            guard let converted = currency.rates?.convert(value, from: selection.from.symbol, to: selection.to.symbol) else {
                return nil
            }
            return UnitConverter.formatCurrency(converted)
        }
        return UnitConverter.format(UnitConverter.convert(value, from: selection.from, to: selection.to))
    }

    /// Swapping moves the current answer into the value field, so flipping
    /// direction keeps you looking at the same quantity.
    private func swapUnits() {
        if let resultText { input = resultText }
        selection.swapUnits()
    }

    private func copyResult() {
        guard let resultText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

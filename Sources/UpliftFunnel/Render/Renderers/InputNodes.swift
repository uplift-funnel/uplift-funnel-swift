import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Smart input nodes (Spec v2 §3.3), ported from `input_nodes.dart`:
// text/number fields, slider, scale, date field, toggle.

func hapticSelection() {
    #if canImport(UIKit) && !os(watchOS)
    UISelectionFeedbackGenerator().selectionChanged()
    #endif
}

/// Number formatting shared by numeric inputs: whole values render without a
/// fractional part ("70", not "70.0") — the value feeds conditions, so the
/// format must match the Flutter SDK byte-for-byte.
func formatNumber(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(v)
}

// MARK: - text_field

@MainActor
func renderTextField(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    return applyStyle(
        TextFieldControl(
            initial: ctx.boundValue(n.saveTo) ?? "",
            placeholder: ctx.resolve(p["placeholder"]),
            keyboard: p["keyboard"].stringValue,
            multiline: p["multiline"].boolValue == true,
            maxLength: p["max_length"].intValue,
            ctx: ctx,
            // Per-keystroke: state only. The committed value is flushed as
            // one variable_set on editing end / navigation.
            onChanged: { ctx.writeVarLocal(n.saveTo, $0) },
            onCommit: { ctx.writeVarCommit(n.saveTo, $0) }),
        n.style, ctx)
}

/// A text field wired to a bound variable. Local @State keeps the caret
/// while `onChanged` pushes each edit up to the session vars map.
struct TextFieldControl: View {
    let initial: String
    let placeholder: String
    let keyboard: String?
    let multiline: Bool
    let maxLength: Int?
    let ctx: RenderCtx
    let onChanged: (String) -> Void

    /// Fired once with the final text when editing ends (keyboard done /
    /// focus loss) — the analytics commit, vs. per-keystroke `onChanged`.
    var onCommit: ((String) -> Void)?

    @State private var text: String = ""
    @State private var seeded = false
    @State private var lastCommitted = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if multiline {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 16))
                            .foregroundColor(ctx.textSecondary.color)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 16))
                        .foregroundColor(ctx.textPrimary.color)
                        .frame(minHeight: 72, maxHeight: 72)
                        .background(Color.clear)
                        .focused($focused)
                }
            } else {
                TextField(placeholder, text: $text)
                    .font(.system(size: 16))
                    .foregroundColor(ctx.textPrimary.color)
                    .modifier(KeyboardTypeModifier(keyboard: keyboard))
                    .padding(.vertical, 10)
                    .focused($focused)
                    .onSubmit { commit() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .modifier(ControlBox(ctx: ctx))
        .onAppear {
            if !seeded {
                seeded = true
                text = initial
                lastCommitted = initial
            }
        }
        .onChange(of: text) { value in
            var next = value
            if let maxLength, next.count > maxLength {
                next = String(next.prefix(maxLength))
                text = next
            }
            onChanged(next)
        }
        .onChange(of: focused) { isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        guard text != lastCommitted else { return }
        lastCommitted = text
        onCommit?(text)
    }
}

struct KeyboardTypeModifier: ViewModifier {
    let keyboard: String?

    func body(content: Content) -> some View {
        #if canImport(UIKit) && !os(watchOS)
        switch keyboard {
        case "email":
            content.keyboardType(.emailAddress).textInputAutocapitalization(.never)
        case "number":
            content.keyboardType(.decimalPad)
        case "phone":
            content.keyboardType(.phonePad)
        default:
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - number_field

@MainActor
func renderNumberField(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let style = n.props["style"].stringValue ?? "free"
    switch style {
    case "wheel":
        return applyStyle(NumberFieldWheel(n: n, ctx: ctx), n.style, ctx)
    case "unit_toggle":
        return applyStyle(NumberFieldUnitToggle(n: n, ctx: ctx), n.style, ctx)
    case "big_number":
        return applyStyle(BigNumberField(n: n, ctx: ctx), n.style, ctx)
    case "free":
        return applyStyle(NumberFieldFree(n: n, ctx: ctx), n.style, ctx)
    default:
        return applyStyle(NumberFieldStepper(n: n, ctx: ctx), n.style, ctx)
    }
}

struct NumberBounds {
    let min: Double?
    let max: Double?
    let step: Double

    init(_ n: PrimNode) {
        min = n.props["min"].doubleValue
        max = n.props["max"].doubleValue
        step = n.props["step"].doubleValue ?? 1
    }

    func clamp(_ v: Double) -> Double {
        var v = v
        if let min, v < min { v = min }
        if let max, v > max { v = max }
        return v
    }
}

private func boundNumber(_ n: PrimNode, _ ctx: RenderCtx, fallback: Double) -> Double {
    ctx.boundValue(n.saveTo).flatMap { Double($0) } ?? fallback
}

struct NumberFieldFree: View {
    let n: PrimNode
    let ctx: RenderCtx

    @State private var text = ""
    @State private var seeded = false

    var body: some View {
        let bounds = NumberBounds(n)
        let unit = ctx.resolve(n.props["unit"])
        HStack(spacing: 8) {
            TextField("", text: $text)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(ctx.textPrimary.color)
                .multilineTextAlignment(.center)
                .modifier(KeyboardTypeModifier(keyboard: "number"))
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(minWidth: 100, maxWidth: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: ctx.cornerRadius)
                        .strokeBorder(ctx.border.color, lineWidth: 1.5))
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 14))
                    .foregroundColor(ctx.textSecondary.color)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if !seeded {
                seeded = true
                text = formatNumber(boundNumber(n, ctx, fallback: bounds.min ?? 0))
            }
        }
        .onChange(of: text) { value in
            // Typed digits: local write — the committed value flushes once
            // on navigation.
            if let parsed = Double(value) {
                ctx.writeVarLocal(n.saveTo, formatNumber(bounds.clamp(parsed)))
            }
        }
    }
}

struct StepButton: View {
    let glyph: String
    let ctx: RenderCtx
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 22))
                .foregroundColor(ctx.primary.color)
                .frame(width: 40, height: 40)
                .background(Circle().fill(ctx.surface.color))
                .overlay(Circle().strokeBorder(ctx.border.color, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

struct NumberFieldStepper: View {
    let n: PrimNode
    let ctx: RenderCtx

    var body: some View {
        let bounds = NumberBounds(n)
        let unit = ctx.resolve(n.props["unit"])
        let cur = boundNumber(n, ctx, fallback: bounds.min ?? 0)
        HStack(spacing: 16) {
            StepButton(glyph: "−", ctx: ctx) {
                ctx.writeVar(n.saveTo, formatNumber(bounds.clamp(cur - bounds.step)))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatNumber(cur))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(ctx.textPrimary.color)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 14))
                        .foregroundColor(ctx.textSecondary.color)
                }
            }
            .frame(minWidth: 60)
            StepButton(glyph: "+", ctx: ctx) {
                ctx.writeVar(n.saveTo, formatNumber(bounds.clamp(cur + bounds.step)))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One huge centered number that IS the input. min/max clamp on edit; the
/// clamped value is written through the node's binding.
struct BigNumberField: View {
    let n: PrimNode
    let ctx: RenderCtx

    @State private var text = ""
    @State private var seeded = false

    var body: some View {
        let bounds = NumberBounds(n)
        let unit = ctx.resolve(n.props["unit"])
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TextField("", text: $text)
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(ctx.textPrimary.color)
                .multilineTextAlignment(.center)
                .modifier(KeyboardTypeModifier(keyboard: "number"))
                .fixedSize()
                .onSubmit {
                    ctx.writeVarCommit(
                        n.saveTo,
                        formatNumber(bounds.clamp(Double(text) ?? (bounds.min ?? 0))))
                }
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 18))
                    .foregroundColor(ctx.textSecondary.color)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if !seeded {
                seeded = true
                text = formatNumber(boundNumber(n, ctx, fallback: bounds.min ?? 0))
            }
        }
        .onChange(of: text) { value in
            // Typed digits: local write — committed on submit/navigation.
            if let parsed = Double(value) {
                ctx.writeVarLocal(n.saveTo, formatNumber(bounds.clamp(parsed)))
            }
        }
    }
}

/// style `wheel` — a native picker wheel from min to max by step. Capped at
/// 500 rendered stops so a mis-configured tiny step over a huge range can't
/// hang the render.
struct NumberFieldWheel: View {
    let n: PrimNode
    let ctx: RenderCtx

    @State private var selection = 0
    @State private var seeded = false

    private var values: [Double] {
        let bounds = NumberBounds(n)
        let min = bounds.min ?? 0
        let max = bounds.max ?? min + 100
        let step = bounds.step > 0 ? bounds.step : 1
        let count = Swift.min(Swift.max(Int(((max - min) / step).rounded(.down)) + 1, 1), 500)
        return (0..<count).map { min + Double($0) * step }
    }

    var body: some View {
        let values = self.values
        let unit = ctx.resolve(n.props["unit"])
        VStack(spacing: 0) {
            Rectangle().fill(ctx.border.color).frame(height: 1)
            Picker("", selection: $selection) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, v in
                    HStack(spacing: 6) {
                        Text(formatNumber(v))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(ctx.textPrimary.color)
                        if !unit.isEmpty {
                            Text(unit)
                                .font(.system(size: 13))
                                .foregroundColor(ctx.textSecondary.color)
                        }
                    }
                    .tag(index)
                }
            }
            #if !os(macOS)
            .pickerStyle(.wheel)
            #endif
            .frame(height: 158)
            .clipped()
            Rectangle().fill(ctx.border.color).frame(height: 1)
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            let cur = boundNumber(n, ctx, fallback: values.first ?? 0)
            selection = values.firstIndex { abs($0 - cur) < 1e-9 } ?? 0
        }
        .onChange(of: selection) { index in
            guard index >= 0, index < values.count else { return }
            // Fires per wheel tick while scrolling — local write; the
            // session flushes the settled value on navigation.
            ctx.writeVarLocal(n.saveTo, formatNumber(values[index]))
        }
    }
}

/// style `unit_toggle` — the stepper display plus a segmented control that
/// switches which unit label is shown. Display-only: it does not convert the
/// underlying numeric value between units (the schema carries no conversion
/// factors).
struct NumberFieldUnitToggle: View {
    let n: PrimNode
    let ctx: RenderCtx

    @State private var unitIdx = 0

    var body: some View {
        let bounds = NumberBounds(n)
        let cur = boundNumber(n, ctx, fallback: bounds.min ?? 0)
        let units = (n.props["units"].arrayValue ?? [])
            .map { ctx.resolve($0) }
            .filter { !$0.isEmpty }
        let activeUnit = unitIdx < units.count ? units[unitIdx] : nil

        VStack(spacing: 12) {
            HStack(spacing: 16) {
                StepButton(glyph: "−", ctx: ctx) {
                    ctx.writeVar(n.saveTo, formatNumber(bounds.clamp(cur - bounds.step)))
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatNumber(cur))
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(ctx.textPrimary.color)
                    if let activeUnit {
                        Text(activeUnit)
                            .font(.system(size: 14))
                            .foregroundColor(ctx.textSecondary.color)
                    }
                }
                .frame(minWidth: 60)
                StepButton(glyph: "+", ctx: ctx) {
                    ctx.writeVar(n.saveTo, formatNumber(bounds.clamp(cur + bounds.step)))
                }
            }
            if units.count > 1 {
                HStack(spacing: 0) {
                    ForEach(Array(units.enumerated()), id: \.offset) { i, unit in
                        Button {
                            unitIdx = i
                        } label: {
                            Text(unit)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(
                                    i == unitIdx ? ctx.onPrimary.color : ctx.textPrimary.color)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(
                                        i == unitIdx ? ctx.primary.color : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .overlay(Capsule().strokeBorder(ctx.border.color, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - slider

@MainActor
func renderSliderNode(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let saveTo = n.saveTo
    let min = p["min"].doubleValue ?? 0
    let max = p["max"].doubleValue ?? 100
    let stepped = p["style"].stringValue == "stepped"
    let step = p["step"].doubleValue ?? (stepped ? 1 : (max - min) / 100)
    let cur = ctx.boundValue(saveTo).flatMap { Double($0) }
        ?? ((min + max) / 2).rounded()
    let minL = ctx.resolve(p["min_label"])
    let maxL = ctx.resolve(p["max_label"])

    func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    return applyStyle(
        VStack(spacing: 2) {
            Text(formatNumber(cur))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(ctx.primary.color)
            SliderControl(
                value: Swift.min(Swift.max(cur, min), max),
                range: min...Swift.max(max, min + 0.001),
                step: step > 0 ? step : nil,
                tint: ctx.primary,
                // Drag path: local writes per tick, one committed
                // variable_set when the thumb is released.
                onChanged: { ctx.writeVarLocal(saveTo, format($0)) },
                onEnded: { v in
                    ctx.writeVarCommit(saveTo, format(v))
                    hapticSelection()
                })
            if !minL.isEmpty || !maxL.isEmpty {
                HStack {
                    Text(minL)
                        .font(.system(size: 12))
                        .foregroundColor(ctx.textSecondary.color)
                    Spacer(minLength: 0)
                    Text(maxL)
                        .font(.system(size: 12))
                        .foregroundColor(ctx.textSecondary.color)
                }
            }
        }
        .frame(maxWidth: .infinity),
        n.style, ctx)
}

struct SliderControl: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let tint: RGBAColor
    let onChanged: (Double) -> Void
    /// Fired with the settled value when the drag ends — the analytics
    /// commit, vs. per-tick `onChanged`.
    let onEnded: (Double) -> Void

    @State private var local: Double = 0
    @State private var seeded = false

    var body: some View {
        Group {
            if let step {
                Slider(
                    value: $local, in: range, step: step,
                    onEditingChanged: { editing in if !editing { onEnded(local) } })
            } else {
                Slider(
                    value: $local, in: range,
                    onEditingChanged: { editing in if !editing { onEnded(local) } })
            }
        }
        .accentColor(tint.color)
        .onAppear {
            if !seeded {
                seeded = true
                local = value
            }
        }
        .onChange(of: local) { onChanged($0) }
    }
}

// MARK: - scale

@MainActor
func renderScale(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let saveTo = n.saveTo
    let minV = p["min"].intValue ?? 1
    let maxV = p["max"].intValue ?? 5
    let style = p["style"].stringValue ?? "numeric"
    let cur = ctx.boundValue(saveTo)
    let radius = ctx.cornerRadius
    let accent = ctx.color(p["accent"].stringValue, fallback: ctx.primary)

    // A custom ramp only applies when it covers every step; a partial set
    // would silently mislabel the middle of the scale.
    let steps = maxV - minV + 1
    let custom = p["emojis"].arrayValue?.compactMap { $0.stringValue }
    let defaultRamp = ["😖", "🙁", "😐", "🙂", "😄"]
    let hasCustom = custom != nil && custom!.count == steps

    func smiley(_ v: Int) -> String {
        if hasCustom { return custom![v - minV] }
        let denom = Double(maxV - minV == 0 ? 1 : maxV - minV)
        let t = Double(v - minV) / denom
        let idx = Swift.min(Swift.max(Int(t * Double(defaultRamp.count)), 0), defaultRamp.count - 1)
        return defaultRamp[idx]
    }

    let minLabel = ctx.resolve(p["min_label"])
    let maxLabel = ctx.resolve(p["max_label"])

    @ViewBuilder
    func cell(_ v: Int) -> some View {
        let sel = cur == String(v)
        switch style {
        case "dots":
            Circle()
                .fill(sel ? accent.color : ctx.surface.color)
                .frame(maxWidth: 44, maxHeight: 44)
                .aspectRatio(1, contentMode: .fit)
        case "smileys":
            Text(smiley(v))
                .font(.system(size: 26))
                .scaleEffect(sel ? 1.15 : 1)
                .opacity(cur == nil ? 1 : (sel ? 1 : 0.4))
        default:
            Text(String(v))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(sel ? accent.color : ctx.textPrimary.color)
                .frame(maxWidth: 48, maxHeight: 48)
                .aspectRatio(1, contentMode: .fit)
                .background(
                    RoundedRectangle(cornerRadius: radius)
                        .fill(sel ? accent.opacity(0.12).color : ctx.surface.color))
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(sel ? accent.color : ctx.border.color, lineWidth: 1.5))
        }
    }

    let row = HStack(spacing: 8) {
        ForEach(minV...maxV, id: \.self) { v in
            Button {
                hapticSelection()
                ctx.writeVar(saveTo, String(v))
            } label: {
                cell(v).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
    }

    return applyStyle(
        VStack(spacing: 6) {
            row
            if !minLabel.isEmpty || !maxLabel.isEmpty {
                HStack {
                    Text(minLabel)
                        .font(.system(size: 12))
                        .foregroundColor(ctx.textSecondary.color)
                    Spacer(minLength: 0)
                    Text(maxLabel)
                        .font(.system(size: 12))
                        .foregroundColor(ctx.textSecondary.color)
                }
            }
        },
        n.style, ctx)
}

// MARK: - date_field

/// ISO-8601 date (yyyy-MM-dd) — what `bind.save_to` stores, and what the
/// schema's `min`/`max` are expressed in. Must match the Flutter SDK
/// byte-for-byte since it feeds conditions.
func isoDate(_ date: Date) -> String {
    let c = Calendar(identifier: .gregorian)
        .dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

func parseIsoDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    let parts = s.split(separator: "-")
    guard parts.count == 3,
          let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
        return nil
    }
    var comps = DateComponents()
    comps.year = y; comps.month = m; comps.day = d
    return Calendar(identifier: .gregorian).date(from: comps)
}

@MainActor
func renderDateField(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    applyStyle(DateFieldControl(n: n, ctx: ctx), n.style, ctx)
}

struct DateFieldControl: View {
    let n: PrimNode
    let ctx: RenderCtx

    @State private var showingPicker = false
    @State private var pickerDate = Date()

    var body: some View {
        let value = ctx.boundValue(n.saveTo) ?? ""
        // Placeholder mirrors the browser's empty `<input type=date>`.
        let placeholder = ctx.locale == "tr" ? "gg.aa.yyyy" : "mm/dd/yyyy"
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let year = calendar.component(.year, from: now)
        let first = parseIsoDate(n.props["min"].stringValue)
            ?? calendar.date(from: DateComponents(year: year - 100, month: 1, day: 1))!
        let last = parseIsoDate(n.props["max"].stringValue)
            ?? calendar.date(from: DateComponents(year: year + 5, month: 1, day: 1))!
        // Defaults span a plausible human lifetime so a date-of-birth field
        // opens somewhere useful rather than at today.
        let defaultInitial = calendar.date(
            from: DateComponents(year: year - 25, month: 1, day: 1))!
        let initial = parseIsoDate(value)
            ?? (first > defaultInitial ? first : defaultInitial)

        Button {
            pickerDate = min(max(initial, first), last)
            showingPicker = true
        } label: {
            HStack {
                Text(value.isEmpty ? placeholder : value)
                    .font(.system(size: 16))
                    .foregroundColor(
                        value.isEmpty ? ctx.textSecondary.color : ctx.textPrimary.color)
                Spacer(minLength: 0)
                Image(systemName: "calendar")
                    .font(.system(size: 16))
                    .foregroundColor(ctx.textPrimary.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .modifier(ControlBox(ctx: ctx))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingPicker) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") {
                        ctx.writeVar(n.saveTo, isoDate(pickerDate))
                        showingPicker = false
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .padding()
                }
                DatePicker(
                    "", selection: $pickerDate, in: first...last,
                    displayedComponents: .date)
                #if !os(macOS)
                .datePickerStyle(.wheel)
                #endif
                .labelsHidden()
                Spacer(minLength: 0)
            }
            .presentationDetentsMediumIfAvailable()
        }
    }
}

extension View {
    /// Medium sheet detent on iOS 16+, full sheet on iOS 15 — cosmetic only.
    @ViewBuilder
    func presentationDetentsMediumIfAvailable() -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            self.presentationDetents([.medium])
        } else {
            self
        }
    }
}

// MARK: - toggle

@MainActor
func renderToggle(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let saveTo = n.saveTo
    let raw = ctx.boundValue(saveTo)
    let on = raw == nil ? (p["default"].boolValue == true) : raw == "true"
    let label = ctx.resolve(p["label"])

    return applyStyle(
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 16))
                .foregroundColor(ctx.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                ctx.writeVar(saveTo, on ? "false" : "true")
            } label: {
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule()
                        .fill(on ? ctx.primary.color : ctx.border.color)
                        .frame(width: 48, height: 28)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 22, height: 22)
                        .shadow(color: Color.black.opacity(0.3), radius: 1.5, y: 1)
                        .padding(3)
                }
                .animation(.easeInOut(duration: 0.15), value: on)
            }
            .buttonStyle(.plain)
        },
        n.style, ctx)
}

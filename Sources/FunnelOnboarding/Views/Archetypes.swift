import SwiftUI

// Minimal v1 SwiftUI views for the four foundational archetypes. Visual
// polish + the remaining 14 archetypes land in subsequent sprints — this
// is the skeleton that proves the dispatch + theme + session wiring
// compiles end-to-end against `swift build`.

struct WelcomeArchetypeView: View {
    let content: WelcomeContent
    let session: FlowSession

    @Environment(\.funnelTheme) private var theme

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(content.title)
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textPrimary)
            if let subtitle = content.subtitle {
                Text(subtitle)
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button(content.ctaLabel) {
                try? session.advance()
            }
            .buttonStyle(PrimaryButtonStyle(theme: theme, enabled: true))
        }
        .padding(24)
    }
}

struct SingleChoiceArchetypeView: View {
    let content: SingleChoiceContent
    let session: FlowSession

    @Environment(\.funnelTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(content.question)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            if let subtitle = content.subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            }
            ForEach(content.options, id: \.value) { option in
                Button {
                    let auto = content.autoAdvance ?? true
                    try? session.setVariable(content.saveTo, AnyHashable(option.value), advance: auto)
                } label: {
                    HStack {
                        if let emoji = option.emoji {
                            Text(emoji).font(.system(size: 22))
                        }
                        Text(option.label)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                            .fill(theme.surface)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(24)
    }
}

struct ScaleArchetypeView: View {
    let content: ScaleContent
    let session: FlowSession
    @State private var selected: Int? = nil

    @Environment(\.funnelTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(content.question)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            if let subtitle = content.subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                ForEach(Array(stride(from: content.min, through: content.max, by: 1)), id: \.self) { v in
                    Button {
                        selected = v
                    } label: {
                        Text("\(v)")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(selected == v ? .white : theme.textPrimary)
                            .background(
                                Circle().fill(selected == v ? theme.primary : theme.surface)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text(content.minLabel ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text(content.maxLabel ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button("Continue") {
                if let v = selected {
                    try? session.setVariable(content.saveTo, AnyHashable(v), advance: true)
                }
            }
            .buttonStyle(PrimaryButtonStyle(theme: theme, enabled: selected != nil))
            .disabled(selected == nil)
        }
        .padding(24)
    }
}

struct FinaleArchetypeView: View {
    let content: FinaleContent
    let session: FlowSession

    @Environment(\.funnelTheme) private var theme

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text(content.title)
                .font(.system(size: 32, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textPrimary)
            if let subtitle = content.subtitle {
                Text(subtitle)
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button(content.ctaLabel) {
                if let evt = content.fireEvent { session.emitCustom(evt) }
                try? session.advance()
            }
            .buttonStyle(PrimaryButtonStyle(theme: theme, enabled: true))
        }
        .padding(24)
    }
}

struct UnsupportedArchetypeView: View {
    let archetype: Archetype
    let session: FlowSession

    @Environment(\.funnelTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: 48))
                .foregroundStyle(theme.textSecondary)
            Text("\(archetype.rawValue) not yet supported")
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textPrimary)
            Text("This archetype will render in a later v1 patch — the iOS SDK ships welcome / single_choice / scale / finale today.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Button("Skip") {
                try? session.advance()
            }
            .buttonStyle(PrimaryButtonStyle(theme: theme, enabled: true))
        }
        .padding(24)
    }
}

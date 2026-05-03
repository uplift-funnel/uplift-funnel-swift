import SwiftUI

/// Top-level view. Hosts a [FlowSession] and dispatches the current screen
/// to the appropriate archetype view.

public struct FunnelOnboardingView: View {
    @State private var session: FlowSession
    private let onCompleted: ((_ variables: [String: AnyHashable], _ reason: String) -> Void)?

    public init(
        session: FlowSession,
        onCompleted: ((_ variables: [String: AnyHashable], _ reason: String) -> Void)? = nil
    ) {
        self._session = State(initialValue: session)
        self.onCompleted = onCompleted
    }

    public var body: some View {
        let theme = ResolvedTheme.resolve(session.flow.theme)
        ZStack {
            theme.background.ignoresSafeArea()
            screenView
                .id(session.currentScreen.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.easeOut(duration: 0.28), value: session.currentScreen.id)
        }
        .environment(\.funnelTheme, theme)
        .task {
            for await event in session.events {
                if case .completed(_, let reason, let variables, _) = event {
                    onCompleted?(variables, reason)
                }
            }
        }
    }

    @ViewBuilder
    private var screenView: some View {
        switch session.currentScreen {
        case .welcome(_, let content, _):
            WelcomeArchetypeView(content: content, session: session)
        case .singleChoice(_, let content, _):
            SingleChoiceArchetypeView(content: content, session: session)
        case .scale(_, let content, _):
            ScaleArchetypeView(content: content, session: session)
        case .finale(_, let content, _):
            FinaleArchetypeView(content: content, session: session)
        case .unsupported(_, let archetype, _, _):
            UnsupportedArchetypeView(archetype: archetype, session: session)
        }
    }
}

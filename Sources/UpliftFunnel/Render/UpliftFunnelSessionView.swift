import Foundation
import SwiftUI
import UpliftLayout

// Renders a live FlowSession, ported from `uplift_funnel_flow_view.dart`
// (named UpliftFunnelSessionView on iOS; the one-shot fetch-by-key widget
// gets the UpliftFunnelFlowView name — see the README mapping table).

public struct UpliftFunnelSessionView: View {
    @ObservedObject var session: FlowSession

    /// Called once when the flow completes (terminal transition or no
    /// outgoing transitions on a finale screen). Receives collected
    /// variables.
    var onCompleted: (([String: JSONValue], String) -> Void)?

    /// Called when the flow is force-ended (abandoned / closed / skipped).
    var onAbandoned: (([String: JSONValue], String) -> Void)?

    var reduceMotion = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var listenerToken: UUID?

    public init(
        session: FlowSession,
        onCompleted: (([String: JSONValue], String) -> Void)? = nil,
        onAbandoned: (([String: JSONValue], String) -> Void)? = nil
    ) {
        self.session = session
        self.onCompleted = onCompleted
        self.onAbandoned = onAbandoned
    }

    /// Reasons that count as the user bailing on the flow rather than
    /// finishing it.
    private static let abandonReasons: Set<String> = ["abandoned", "closed", "skipped"]

    public var body: some View {
        let theme = PrimTheme.resolve(
            themeJson: session.flow.raw["theme"], dark: colorScheme == .dark)
        let screen = session.currentScreen
        let backgroundColor = RGBA.parse(theme.colors["background"]) ?? .white

        // Direction-aware slide+fade: forward pushes the new screen in from
        // the trailing edge while the old one exits toward the leading edge;
        // back navigation mirrors both, so a pop visibly moves backwards.
        let isBack = session.lastNavWasBack
        let transition: AnyTransition = .asymmetric(
            insertion: .move(edge: isBack ? .leading : .trailing)
                .combined(with: .opacity),
            removal: .move(edge: isBack ? .trailing : .leading)
                .combined(with: .opacity))

        return ZStack {
            Color(backgroundColor).ignoresSafeArea()
            // `showBack` is captured BY VALUE at screen entry: the outgoing
            // view keeps the chevron state it was entered with instead of
            // reacting to the shared session history flipping mid-fade (the
            // "back button pops in before the transition" bug).
            host(screen: screen, theme: theme, showBack: session.canGoBack)
                .id(screen.id)
                .transition(reduceMotion ? .opacity : transition)
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.28), value: screen.id)
        .onAppear {
            guard listenerToken == nil else { return }
            listenerToken = session.addEventListener { event in
                handle(event)
            }
        }
        .onDisappear {
            if let token = listenerToken {
                session.removeEventListener(token)
                listenerToken = nil
            }
        }
    }

    @MainActor
    private func host(
        screen: FunnelScreen, theme: PrimTheme, showBack: Bool
    ) -> some View {
        let configured = UpliftFunnel.isConfigured
        let signIn: SignInHandler? = configured
            ? UpliftFunnel.lookupSignInHandler() : nil
        let permission: PermissionHandler? = configured
            ? UpliftFunnel.lookupPermissionHandler() : nil
        let photoUpload: PhotoUploadHandler? = configured
            ? UpliftFunnel.lookupPhotoUploadHandler() : nil
        let purchase: PurchaseHandler? = configured
            ? UpliftFunnel.lookupPurchaseHandler() : nil
        let restore: RestoreHandler? = configured
            ? UpliftFunnel.lookupRestoreHandler() : nil
        var view = PrimitiveScreenHost(
            screen: screen,
            session: session,
            primFlow: session.primFlow,
            theme: theme)
        view.showBack = showBack
        view.onSignIn = signIn
        view.onPermission = permission
        view.onPhotoUpload = photoUpload
        view.onPurchase = purchase
        view.onRestore = restore
        view.reduceMotion = reduceMotion
        return view
    }

    private func handle(_ event: FlowEvent) {
        switch event {
        case .completed(_, _, let reason, let variables):
            if Self.abandonReasons.contains(reason) {
                onAbandoned?(variables, reason)
            } else {
                onCompleted?(variables, reason)
            }
        case .custom(_, _, let name, _) where name.hasPrefix("url:"):
            // `url:<href>` actions (markdown links, url: buttons) surface
            // here as custom events — route them to the host's link opener.
            // `openLink` drops schemes the host hasn't allowed before the
            // handler sees them; the href is authored content off the network.
            if UpliftFunnel.isConfigured {
                UpliftFunnel.openLink(String(name.dropFirst("url:".count)))
            }
        default:
            break
        }
    }
}

extension FlowSession {
    private static var primFlowCache = [ObjectIdentifier: PrimFlow]()

    /// PrimFlow parsed once per session (the flow JSON doesn't change
    /// screen-to-screen).
    var primFlow: PrimFlow {
        let key = ObjectIdentifier(self)
        if let cached = Self.primFlowCache[key] { return cached }
        let parsed = PrimFlow(json: flow.raw)
        Self.primFlowCache[key] = parsed
        // Bounded cleanup: sessions are few; drop stale entries eagerly.
        if Self.primFlowCache.count > 8 {
            Self.primFlowCache = [key: parsed]
        }
        return parsed
    }
}

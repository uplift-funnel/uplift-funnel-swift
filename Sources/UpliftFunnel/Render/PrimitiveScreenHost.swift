import Foundation
import SwiftUI

// Bridges a live FlowSession to the standalone PrimitiveScreenView renderer,
// ported from `primitive_screen_host.dart`. Turns session state (current
// screen id, variables) into the (PrimFlow, screenIndex, locale, vars,
// selections) shape the renderer expects, and wires `onAction`/`onSave`
// back into the session — plus the purchase-analytics bridge.

struct PrimitiveScreenHost: View {
    let screen: FunnelScreen
    @ObservedObject var session: FlowSession
    let primFlow: PrimFlow
    let theme: PrimTheme

    /// Back-chevron visibility captured by the session view at screen entry.
    /// Passed by value so an outgoing screen mid-transition keeps the state
    /// it was entered with (reading `session.canGoBack` live would flip the
    /// chevron on the old screen the instant history changes). Nil falls
    /// back to the live session value (standalone hosting, tests).
    var showBack: Bool?
    var onSignIn: ((String) async -> Bool)?
    var onPermission: ((String) async -> Bool)?
    var onPhotoUpload: ((PhotoUploadRequest) async -> String?)?
    /// Host billing handoff, wrapped here with plan → store-product
    /// resolution and purchase analytics before it reaches the renderer.
    var onPurchase: PurchaseHandler?
    var onRestore: (() async -> Bool)?
    var reduceMotion = false

    var body: some View {
        let flow = session.flow
        let screenIndex = flow.screens.firstIndex { $0.id == screen.id } ?? 0
        let locale = resolveLocale(
            locales: primFlow.locales, defaultLocale: primFlow.defaultLocale)
        let vars = stringifyVariables(session.variables)

        PrimitiveScreenView(
            flow: primFlow,
            theme: theme,
            screenIndex: screenIndex,
            locale: locale,
            vars: vars,
            selections: vars,
            canGoBack: showBack ?? session.canGoBack,
            // Stamped with the screen that raised it, so a timer firing after
            // the user has moved on is dropped rather than skipping a screen.
            onAction: { session.handleAction($0, fromScreenId: screen.id) },
            // A JSON-array string coming back from the renderer is a
            // multi-select value — store the real array so transition
            // conditions (`contains`) and analytics see an array_string,
            // not a serialized blob.
            onSave: { saveTo, value in
                session.setVariable(saveTo, decodeValue(value))
            },
            // Typing/dragging path: same state write, no analytics event —
            // the final value flushes as ONE variable_set on navigation or
            // editing end.
            onSaveLocal: { saveTo, value in
                session.setVariableLocal(saveTo, decodeValue(value))
            },
            // Editing-end commit: apply the final value, then flush only
            // this name's pending event (no-op if a navigation flush got
            // there first).
            onSaveCommit: { saveTo, value in
                session.setVariableLocal(saveTo, decodeValue(value))
                session.commitVariable(saveTo)
            },
            onSignIn: onSignIn,
            onPermission: onPermission,
            onPhotoUpload: onPhotoUpload,
            // Nil stays nil: the renderer's no-handler behavior (purchase
            // just advances — preview/unwired mode) must not produce
            // analytics events.
            onPurchase: onPurchase == nil ? nil : handlePurchase,
            onRestore: onRestore,
            reduceMotion: reduceMotion)
    }

    private func handlePurchase(_ planId: String?) async -> Bool {
        await performPurchaseBridge(
            session: session, screenId: screen.id,
            plan: findPlan(planId), planId: planId,
            handler: onPurchase!)
    }

    /// Raw plan JSON with `planId` from the current screen's first
    /// `plan_picker`, falling back to the highlighted (else lone) plan when
    /// nothing was picked yet — single-plan paywalls have no selection step.
    private func findPlan(_ planId: String?) -> JSONValue? {
        guard let root = primFlow.screens.first(where: { $0.id == screen.id })?.root,
              let picker = findPlanPicker(root) else {
            return nil
        }
        let plans = (picker.props["plans"].arrayValue ?? [])
            .filter { $0.objectValue != nil }
        if plans.isEmpty { return nil }
        guard let planId else {
            // Mirror the renderer's visual default when nothing was tapped:
            // the highlighted plan (cards/toggle preselect it), else a lone
            // plan.
            if let highlighted = plans.first(where: { $0["highlighted"].boolValue == true }) {
                return highlighted
            }
            return plans.count == 1 ? plans[0] : nil
        }
        return plans.first { $0["id"].stringifiedValue == planId }
    }

    private func findPlanPicker(_ node: PrimNode) -> PrimNode? {
        if node.type == "plan_picker" { return node }
        for child in node.children {
            if let found = findPlanPicker(child) { return found }
        }
        return nil
    }

    /// Device locale if the flow declares it, else the flow's default.
    private func resolveLocale(locales: [String], defaultLocale: String) -> String {
        if let deviceCode = DeviceContext.languageCode, locales.contains(deviceCode) {
            return deviceCode
        }
        return defaultLocale
    }
}

/// Bridges the renderer's `purchase` tap to the registered PurchaseHandler:
/// resolves the tapped plan to its platform store product id, tracks the
/// attempt + outcome, and gates advancing on `.purchased`.
@MainActor
func performPurchaseBridge(
    session: FlowSession, screenId: String, plan: JSONValue?, planId: String?,
    handler: PurchaseHandler
) async -> Bool {
    let productId = plan.flatMap { planProductId($0) }
    session.trackPurchase(stage: "attempted", planId: planId, productId: productId)

    let result = await handler(PurchaseRequest(
        flowId: session.flow.id,
        screenId: screenId,
        sessionId: session.sessionId,
        planId: planId,
        productId: productId,
        plan: plan))

    let stage: String
    switch result {
    case .purchased: stage = "succeeded"
    case .cancelled: stage = "cancelled"
    case .failed: stage = "failed"
    case .pending: stage = "pending"
    }
    session.trackPurchase(stage: stage, planId: planId, productId: productId)
    return result == .purchased
}

/// Session vars → renderer strings. Arrays (multi-select `array_string`
/// variables) stringify as a JSON array — the renderer's canonical
/// multi-select encoding — so membership round-trips; everything else is the
/// scalar's plain string form.
func stringifyVariables(_ variables: [String: JSONValue]) -> [String: String] {
    variables.mapValues { v in
        if v.arrayValue != nil { return v.serializedString() }
        return v.stringifiedValue ?? (v.isNull ? "" : v.serializedString())
    }
}

/// Inverse of `stringifyVariables` for values written by the renderer: a
/// JSON-array string decodes back to an array; anything else passes through
/// as the plain string.
func decodeValue(_ value: String) -> JSONValue {
    if value.hasPrefix("["),
       let decoded = try? JSONValue.parse(value),
       decoded.arrayValue != nil {
        return decoded
    }
    return .string(value)
}

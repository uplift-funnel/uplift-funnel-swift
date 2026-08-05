import SwiftUI
import UpliftFunnel

/// A slot inside a real scrolling list — the shape C3 shipped without proving.
///
/// The two things this screen exists to exercise, both of which unit tests
/// cannot reach because they are about a view hosted inside somebody else's
/// scroll container:
///
///   1. **Gestures.** `UpliftFunnelSlot` hosts SwiftUI content inside a `List`
///      row. A tap on a card in there has to reach the card, and a drag has to
///      reach the list — if the slot swallows the drag, the page stops
///      scrolling wherever the card happens to be.
///   2. **Safe area.** A flow document is authored against a full screen and
///      laid out into whatever box the host gives it. A slot in a list row is a
///      small box in the middle of the page, so anything the engine does with
///      safe-area insets has to be relative to that box and not to the window.
///
/// The slot renders nothing until the server decides something for its id, so
/// this screen looks like an ordinary list until a trigger fires.
struct SlotDemo: View {
    @State private var lastResult = "—"

    var body: some View {
        List {
            Section("Above") {
                ForEach(1...6, id: \.self) { row in
                    Text("Row \(row)")
                }
            }

            Section("Slot") {
                // Sized by the host, as the type's documentation insists: the
                // flow is laid out into this box, and a banner document in a
                // 600-point box draws like a full screen.
                UpliftFunnelSlot(slotId: "home_top") { result in
                    lastResult = "\(result.endReason) · \(result.variables.count) vars"
                }
                .frame(height: 160)
                .listRowInsets(EdgeInsets())
            }

            Section("Below") {
                ForEach(7...30, id: \.self) { row in
                    Text("Row \(row)")
                }
            }

            Section("Last slot result") {
                Text(lastResult).font(.footnote.monospaced())
            }
        }
        .navigationTitle("Slot in a list")
    }
}

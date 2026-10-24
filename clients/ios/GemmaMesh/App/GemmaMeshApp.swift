import SwiftUI

@main
struct GemmaMeshApp: App {
    @State private var model = ChatModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Root()
                .environment(model)
                // iOS suspends the memory server, discovery and the health loop in the background: restart them.
                .onChange(of: phase) { _, p in if p == .active { model.foreground() } }
        }
    }
}

/// The chat, and a swipe left of it the Mesh page: two ordinary views side by side, moved by a horizontal drag.
/// Not a page-style TabView: inside one, iOS 18's navigation bars never see their page's scroll view, so the
/// content started under the bar.
struct Root: View {
    @Environment(ChatModel.self) private var m
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            HStack(spacing: 0) {
                ChatView().frame(width: w).accessibilityHidden(m.screen != 0)
                MeshView().frame(width: w).accessibilityHidden(m.screen != 1)
            }
            .frame(width: w, alignment: .leading)
            .offset(x: -CGFloat(m.screen) * w + drag)
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.86), value: m.screen)
            // Only a strip at the screen's edge turns the page, like the system's back swipe: a drag gesture over
            // the whole page takes the scrolling away from the message list on iOS 18, and with it the drag that
            // puts the keyboard away.
            .overlay(alignment: m.screen == 0 ? .trailing : .leading) {
                if m.screen == 0 || m.meshPath.isEmpty {
                    Color.clear.frame(width: 22).contentShape(Rectangle()).gesture(swipe(width: w))
                        .padding(.vertical, 120)            // clear of the bars and the composer's send button
                }
            }
        }
        // The strips above and below the pages take the colour of the page in front.
        .background((m.screen == 1 ? CP.ground : Theme.background).ignoresSafeArea())
        .onChange(of: m.screen) { _, _ in hideKeyboard() }
    }

    private func swipe(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($drag) { v, state, _ in
                state = m.screen == 0 ? min(0, v.translation.width) : max(0, v.translation.width)
            }
            .onEnded { v in
                let t = v.predictedEndTranslation.width
                if m.screen == 0, t < -w / 4 { m.screen = 1 } else if m.screen == 1, t > w / 4 { m.screen = 0 }
            }
    }
}

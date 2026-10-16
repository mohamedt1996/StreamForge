import SwiftUI

extension View {
    /// Attaches the full-screen player and the multiview grid, both driven by `PlayerCoordinator.shared`.
    /// Use once on the root view (replaces `.fullScreenCover(item: $coordinator.current) { PlayerView(request: $0) }`).
    @MainActor
    func playerPresentation() -> some View {
        modifier(PlayerPresentationModifier())
    }
}

@MainActor
struct PlayerPresentationModifier: ViewModifier {
    @State private var coordinator = PlayerCoordinator.shared

    func body(content: Content) -> some View {
        @Bindable var coordinator = coordinator
        content
            .fullScreenCover(item: $coordinator.current) { request in
                PlayerView(request: request)
            }
            // A separate presenter for multiview, so the two covers never fight over one view.
            .background {
                Color.clear
                    .fullScreenCover(isPresented: Binding(
                        get: { coordinator.multiview != nil },
                        set: { if !$0 { coordinator.multiview = nil } }
                    )) {
                        MultiviewView(channels: coordinator.multiview ?? [])
                    }
            }
    }
}

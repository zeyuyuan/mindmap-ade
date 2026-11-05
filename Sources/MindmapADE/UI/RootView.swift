import SwiftUI

struct RootView: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .frame(minWidth: WindowLayout.minimumWidth, minHeight: WindowLayout.minimumHeight)
            .accessibilityHidden(true)
    }
}

#Preview {
    RootView()
}

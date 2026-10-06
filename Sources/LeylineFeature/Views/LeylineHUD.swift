import AinkradAppKit
import SwiftUI

/// Shared gaming-HUD styling for Leyline, mirroring the host's OverlayChrome /
/// Git Mage vocabulary but synthesized from the 7 `HostThemeTokens` colors only
/// (borders/glows are opacity + gradient derivations of the accents).
enum LeylineHUD {
    /// A horizontal glow hairline used INSTEAD of separator lines.
    static func glowRule(_ t: HostThemeTokens) -> some View {
        LinearGradient(
            colors: [.clear, t.accentSecondary.opacity(0.35), .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 1)
    }

    /// The dark, bordered surface a sheet's content sits on so it reads as a HUD
    /// panel rather than a stock macOS sheet.
    static func sheetBackground(_ t: HostThemeTokens) -> some View {
        ZStack {
            t.background
            LinearGradient(
                colors: [t.accentPrimary.opacity(0.06), .clear],
                startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

import SwiftUI
import AinkradAppKit

/// Leyline's settings surface — an info blurb plus the shared surface rows.
///
/// "Open as" and "Open in" come from `AinkradSurfaceSettings` rather than being
/// spelled out here, so they read the same and sit in the same place in every
/// app. Both are backed by the host's controls, which persist the override;
/// this view keeps no copy of either.
struct LeylineSettingsView: View {
    let presentation: any PluginPresentationControl
    let modeControl: any PluginModeControl

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                Text("Leyline stores connections and keys per workspace.")
                    .font(AinkradFontResolver.font(.body, typography: typo))
                    .foregroundStyle(theme.foreground)

                AinkradSurfaceSettings(appName: "Leyline",
                                       presentation: presentation,
                                       mode: modeControl)
            }
        }
        .padding()
    }
}

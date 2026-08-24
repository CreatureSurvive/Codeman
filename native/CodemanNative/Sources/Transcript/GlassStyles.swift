import SwiftUI

/// Liquid Glass, with a material fallback.
///
/// ⚠️ The app deploys to iOS 18 while building against the iOS 26 SDK, so every glass API needs an
/// availability branch. `glassEffect(_:in:)`, `GlassEffectContainer` and `.buttonStyle(.glass)` are
/// all iOS 26.0+; on 18–25 these fall back to `.regularMaterial`, which is the closest thing the
/// older SDK has and keeps the same shape and padding so nothing shifts.
extension View {
    /// A floating panel: glass on 26, material below.
    func glassPanel(cornerRadius: CGFloat) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }

    /// A compact control inside a panel. `circular` gives an icon-only control a circle rather
    /// than a capsule, which is what makes `+` read as a button and not a squashed pill.
    func composerPillStyle(circular: Bool = false) -> some View {
        modifier(GlassPillModifier(circular: circular))
    }

    /// The send button. Glass in both states — enabled reads as raised and full-contrast,
    /// disabled as recessed and dim. Deliberately NOT accent-tinted: the composer sits on glass,
    /// and a saturated fill is the one thing that breaks that surface.
    func composerSendStyle(enabled: Bool) -> some View {
        modifier(GlassSendModifier(enabled: enabled))
    }
}

private struct GlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.quaternary, lineWidth: 0.5) }
        }
    }
}

private struct GlassPillModifier: ViewModifier {
    let circular: Bool

    func body(content: Content) -> some View {
        // `Capsule` on a square frame is a circle geometrically, but naming the shape keeps the
        // intent legible and survives a future height change.
        let shape = AnyShape(circular ? AnyShape(Circle()) : AnyShape(Capsule()))
        if #available(iOS 26.0, *) {
            // `.interactive()` is what gives a pill its press response inside a glass panel.
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(.thinMaterial, in: shape)
                .overlay { shape.stroke(.quaternary, lineWidth: 0.5) }
        }
    }
}

private struct GlassSendModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        // An empty composer must read as unavailable, not merely quiet: same glass, but the
        // symbol drops to a disabled tint and the whole control loses contrast.
        if #available(iOS 26.0, *) {
            content
                .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color(.tertiaryLabel)))
                .glassEffect(enabled ? .regular.interactive() : .regular, in: Circle())
                .opacity(enabled ? 1 : 0.55)
        } else {
            content
                .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color(.tertiaryLabel)))
                .background(enabled ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial), in: Circle())
                .overlay { Circle().strokeBorder(.quaternary, lineWidth: 0.5) }
                .opacity(enabled ? 1 : 0.55)
        }
    }
}

/// The jump-to-latest control.
///
/// Centred rather than trailing, glass rather than accent-tinted, and scaled in and out — an
/// element that appears and disappears with the reader's scroll position should animate on both
/// edges, not pop.
struct ScrollToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .glassCircle()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to latest")
        .accessibilityIdentifier("transcript.jumpToLatest")
        // Symmetric scale so it retracts the way it arrived instead of vanishing.
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

private extension View {
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.quaternary, lineWidth: 0.5) }
        }
    }
}

/// A neutral call-to-action for the transcript's empty states.
///
/// `.borderedProminent` paints the accent colour, which is exactly what the composer's glass
/// surface is trying to avoid; this keeps the emphasis without the tint.
struct GlassActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassPanel(cornerRadius: 22)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == GlassActionButtonStyle {
    static var glassAction: GlassActionButtonStyle { GlassActionButtonStyle() }
}

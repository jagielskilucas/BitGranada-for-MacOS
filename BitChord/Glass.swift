//
//  Glass.swift
//  BitChord for macOS
//
//  Apple's Liquid Glass, via the APIs the Landmarks sample uses:
//  `.glassEffect(_:in:)`, `GlassEffectContainer`, `.glassEffectID(_:in:)` and
//  `.buttonStyle(.glass)`.
//
//  They are macOS 26-only, and this app still runs on macOS 14, so every entry
//  point here degrades to the hand-rolled `NSVisualEffectView` glass the rest of
//  the app was already using. Compile with the macOS 26 SDK; the deployment
//  target stays at 14.
//

import SwiftUI
import AppKit

// MARK: - Availability

enum LiquidGlass {
    /// Whether the running system draws the real thing.
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

// MARK: - Glass on an arbitrary shape

extension View {
    /// The official Liquid Glass surface, tinted and optionally interactive, on
    /// macOS 26; the blur-plus-hairline fallback everywhere else.
    @ViewBuilder
    func liquidGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                if interactive {
                    self.glassEffect(.regular.tint(tint).interactive(), in: shape)
                } else {
                    self.glassEffect(.regular.tint(tint), in: shape)
                }
            } else {
                if interactive {
                    self.glassEffect(.regular.interactive(), in: shape)
                } else {
                    self.glassEffect(.regular, in: shape)
                }
            }
        } else {
            self.modifier(FallbackGlass(shape: shape, tint: tint))
        }
    }

    /// Clear glass — for surfaces that sit on artwork and should not add a
    /// colour of their own.
    @ViewBuilder
    func liquidClearGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                self.glassEffect(.clear.interactive(), in: shape)
            } else {
                self.glassEffect(.clear, in: shape)
            }
        } else {
            self.modifier(FallbackGlass(shape: shape, tint: nil, clear: true))
        }
    }
}

/// macOS 14/15 fallback: the blur, a surface tint and a 1 pt rim — the same
/// material the bars used before Liquid Glass existed.
private struct FallbackGlass<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color?
    var clear: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    BlurMaterial()
                    if clear {
                        Color.clear
                    } else {
                        (tint ?? Color.black.opacity(0.25))
                    }
                }
                .clipShape(shape)
            }
            .overlay {
                shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
    }
}

// MARK: - Controls

/// The circular control used in the top bar. On macOS 26 it is a real glass
/// button; before that it keeps the hover disc.
struct GlassCircleButton: View {
    var systemName: String
    var size: CGFloat = 44
    var glyph: CGFloat = 18
    var theme: BitTheme
    var help: String? = nil
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: glyph, weight: .semibold))
                    .foregroundStyle(theme.colors.onSurface)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .tint(.clear)
            .clipShape(Circle())
            .help(help ?? "")
        } else {
            CircleIconButton(systemName: systemName, size: size, glyph: glyph, theme: theme, action: action)
                .help(help ?? "")
        }
    }
}

// MARK: - Container

/// Wraps children in a `GlassEffectContainer` on macOS 26 so their glass blurs
/// and merges as one surface (the sample's `BadgesView` pattern); a plain
/// `ZStack` otherwise.
struct LiquidGlassContainer<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            ZStack { content() }
        }
    }
}

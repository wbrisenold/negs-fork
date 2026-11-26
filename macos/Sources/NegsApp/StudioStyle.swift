import AppKit
import SwiftUI

/// Shared graphite surfaces and compact spacing for the Library and editor inspector.
enum StudioStyle {
    enum Space {
        static let tight: CGFloat = 3
        static let compact: CGFloat = 6
        static let standard: CGFloat = 9
        static let section: CGFloat = 12
        static let paneInset: CGFloat = 8
    }

    enum Radius {
        static let control: CGFloat = 4
        static let card: CGFloat = 5
        static let panel: CGFloat = 6
        static let pane: CGFloat = 12
    }

    enum ActionRole {
        static let primary = Theme.accent
        static let secondary = Theme.label
        static let quiet = Theme.dim
        static let focus = Theme.accent
        static let disabledOpacity = Theme.disabledOpacity
    }

    enum ActionKind: Equatable {
        case primary
        case secondary
    }

    enum Layout {
        static let editorPresetSidebarWidth: CGFloat = 280
    }

    enum Typography {
        static let section = Font.system(size: 10, weight: .semibold)
        static let sectionTracking: CGFloat = 0.65
        static let label = Font.system(size: 11)
        static let value = Font.system(size: 11, weight: .medium).monospacedDigit()
        static let caption = Font.system(size: 10)
    }

    // Share the Omarchy graphite and amber tokens with the editor rather than
    // letting the Library drift back to its older blue palette.
    static let window = Theme.bg
    static let sidebar = Theme.film
    static let panel = Theme.panel
    static let plot = Theme.film
    static let subtle = Theme.line.opacity(0.35)
    static let outline = Theme.line.opacity(0.9)
    static let accent = Theme.accent
    static let positive = Color(red: 0.42, green: 0.68, blue: 0.38)
    static let negative = Theme.warn
    static let warning = Theme.warn
}

extension View {
    /// One inset surface treatment for the Library bins, photo inspector, and editor rail.
    func studioWorkspacePane(surface: Color = StudioStyle.panel) -> some View {
        let shape = RoundedRectangle(cornerRadius: StudioStyle.Radius.pane, style: .continuous)
        return background(surface, in: shape)
            .overlay(shape.strokeBorder(StudioStyle.outline, lineWidth: 0.8))
            .clipShape(shape)
    }

    /// A compact square card surface shared by Library scope guidance and editor panels.
    func studioWorkspaceCard(surface: Color = StudioStyle.panel) -> some View {
        let shape = RoundedRectangle(cornerRadius: StudioStyle.Radius.card, style: .continuous)
        return background(surface, in: shape)
            .overlay(shape.strokeBorder(StudioStyle.outline, lineWidth: 0.8))
            .clipShape(shape)
    }
}

struct StudioActionButtonStyle: ButtonStyle {
    var kind: StudioStyle.ActionKind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        StyledAction(configuration: configuration, kind: kind)
    }

    private struct StyledAction: View {
        let configuration: ButtonStyle.Configuration
        let kind: StudioStyle.ActionKind
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovered = false

        var body: some View {
            let primary = kind == .primary
            let shape = RoundedRectangle(cornerRadius: StudioStyle.Radius.control, style: .continuous)
            return configuration.label
                .font(Theme.text(11, weight: primary ? 600 : 500))
                .foregroundStyle(primary ? Theme.onAccent : StudioStyle.ActionRole.secondary)
                .padding(.horizontal, 11).frame(minHeight: 30)
                .background(shape.fill(primary ? Theme.accent.opacity(configuration.isPressed ? 0.75 : hovered ? 0.9 : 0.78) : Theme.panel))
                .overlay(shape.strokeBorder(focused ? StudioStyle.ActionRole.focus : StudioStyle.outline, lineWidth: focused ? 1.5 : 0.8))
                .contentShape(shape)
                .opacity(enabled ? 1 : StudioStyle.ActionRole.disabledOpacity)
                .onHover { hovered = $0 && enabled }
        }
    }
}

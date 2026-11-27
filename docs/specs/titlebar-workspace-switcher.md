# Title-bar Library and Develop switcher

## Problem Statement

The Library and Develop controls at the upper left of the main window look like two unrelated, oversized buttons. Their labels and icons consume space beside the traffic lights, while the filename is squeezed into the remaining title band. More importantly, the controls appear clickable but currently have no target assigned, so their actions may not reach `TitleBand.showLibrary()` or `TitleBand.showDevelop()`. The user reports that both controls are ugly and do not work.

This is a high-frequency navigation path between browsing photographs and editing them. It must respond reliably, show which workspace is active, and read as one compact control that belongs in the macOS title bar.

## Solution

Replace the independent Library and Develop buttons with one compact, native macOS segmented workspace switcher in the same title-bar position. The segments remain explicitly named **Library** and **Develop**. Use the app's existing theme colors and selected-state treatment, but keep the control visually quiet and proportionate to the title bar. Leave room for the filename and existing title-bar actions.

Selecting Library must show the Library workspace and select the Library segment. Selecting Develop must follow the existing `editFromCurrentWorkspace` behavior and select Develop only when that behavior can enter the editor. Switching workspaces must preserve the current photograph, edits, and library selection according to the current model behavior. Selecting the already active workspace is safe and does not reset state.

The switcher must have working action targets, a clear VoiceOver/accessibility name and selected state, and respond to real pointer clicks. Keep it visible only in the same app state where the current studio controls are visible. Existing title-bar drag behavior outside interactive controls must remain intact.

## User Stories

1. As a photographer, I can click Library and see the Library workspace immediately.
2. As a photographer, I can click Develop and return to the current edit when one exists.
3. As a photographer, when I select a photo in Library and choose Develop, the existing selected-photo development behavior is used.
4. As a photographer, I can tell which workspace is active without interpreting two unrelated buttons.
5. As a photographer, the workspace control takes less visual weight than the filename and the traffic-light controls.
6. As a photographer, I can move between workspaces repeatedly without losing the selected photo or current edit state.
7. As a photographer, choosing the active workspace again does not reset the workspace or its selection.
8. As a keyboard and assistive-technology user, the switcher exposes two named choices and announces the selected workspace.
9. As a keyboard user, the workspace choices can be focused and activated using standard macOS control behavior.
10. As a photographer, the title band remains draggable from its noninteractive area.
11. As a photographer, the switcher remains correctly placed and legible after resizing the window and entering full screen.
12. As a photographer, the control uses the existing Negs theme and remains legible in supported macOS appearances.
13. As a photographer, the filename and existing Export/Adjustments controls do not overlap the workspace switcher at the supported minimum window size.
14. As a photographer, changing workspaces does not accidentally trigger Export, Adjustments, window dragging, or window zooming.
15. As a maintainer, the switcher state is synchronized from `EditorModel.workspace`, rather than being a second independent source of truth.

## Implementation Decisions

- Use a single native `NSSegmentedControl` configured for one selected segment, with Library and Develop labels and appropriate symbols.
- Keep the existing title-band location, model routing, and visibility rules unless the UI test demonstrates they prevent correct operation.
- Connect the native control to an explicit target/action path. Do not rely on an implicit or nil target.
- Derive selected state from the model whenever the title band refreshes; switching from Library to Develop must respect the existing selection/edit behavior.
- Preserve the title band's hit-testing contract so only the switcher and other interactive title-bar actions receive clicks.
- Use semantic theme colors and native control states. Do not add new persistent preferences or a second workspace enum.
- Do not redesign the rest of the title bar or Library/Develop workspace layouts in this ticket.

## Testing Decisions

### Public behavior

- One macOS UI integration test activates the actual title-bar Library and Develop controls in turn and verifies the selected workspace and visible workspace content.
- Cover Develop with an existing edit, Develop from a Library selection, and the no-current-photo case so the switcher does not claim a transition that did not happen.
- Verify repeated activation is safe and workspace switching preserves relevant selection/edit state.
- Verify the active segment is synchronized after workspace changes initiated outside the switcher.
- Verify keyboard/accessibility exposure includes both choices and the active selection.
- Verify the title band still supports dragging outside the control and the switcher does not overlap neighboring title-bar actions at the minimum supported window size and in full screen.
- Visually inspect the running Intel macOS app for hierarchy, spacing, selected/unselected states, and legibility. A passing unit test or compile alone does not establish that the reported visible issue is fixed.

### Modules and existing coverage

- `macos/Sources/NegsApp/TitleBar.swift`: `TitleBand` controls, target/action wiring, selection state, layout, and hit testing.
- `macos/Sources/NegsApp/EditorWindowController.swift`: workspace routing and current edit/library selection semantics.
- `macos/Tests/NegsTests/TitleBarTests.swift`: existing title-band geometry/layout coverage.
- `macos/Tests/NegsTests/WorkspaceRoutingTests.swift`: existing workspace behavior coverage; currently no test activates the title-bar workspace controls.

### Test seam

Use one macOS UI integration seam that activates the real title-bar control and checks workspace state and visible content. Supplement it with a visible Intel-app appearance check; visual polish cannot be established by the integration test alone.

## Out of Scope

- Redesigning the full Library screen, Develop screen, or other toolbar controls.
- Changing the Library/Develop names or introducing a new navigation model.
- Changing library selection, batch development, export, or edit semantics beyond making the switcher faithfully invoke existing behavior.
- Adding workspace shortcuts or a persistent workspace preference.
- Replacing the title bar, changing traffic-light placement, or changing the filename display.

## Further Notes

- Relevant source: `TitleBand` in `TitleBar.swift`; `showLibraryWorkspace` and `editFromCurrentWorkspace` in `EditorWindowController.swift`.
- Current tests exercise title-band geometry and Library keyboard/menu behavior, but do not activate the title-bar Library/Develop controls.
- The source currently assigns actions to the two controls but does not set their `target`; the integration test should prove the user-visible route rather than only inspecting those properties.

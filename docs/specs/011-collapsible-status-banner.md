# Spec 011 — Collapsible status banner

Status: implemented

## Problem

The main window reserves the status banner's intrinsic height even when the
banner is hidden. Once startup notices and actionable warnings are gone, this
leaves an empty strip between the toolbar and the destination/inspector split
view.

## Behaviour

- When Escapement has an actionable status notice, the banner appears across
  the top of the window with its existing message and action.
- When no notice applies, the banner occupies zero height and the split view
  begins at the top of the content area.
- Showing or hiding the banner does not resize or move the window.
- Existing banner priority, wording, actions, appearance, and accessibility
  remain unchanged.
- Repeated refreshes and transitions between visible and hidden states do not
  accumulate constraints or leave stale space.

## Verification

The application target cannot be `@testable`-imported. Verify this layout
contract in the signed application:

1. Capture the current hidden-banner state and confirm the empty strip exists.
2. Install the changed build and confirm the split view reaches the top of the
   content area when no banner applies.
3. Put the app into a state with an actionable notice and confirm the banner
   expands normally without resizing the window.
4. Clear the notice and confirm the same window collapses the region again.
5. Run the full `EscapementKit` suite to guard the state that selects which
   banner is shown, and verify the release build and signature.

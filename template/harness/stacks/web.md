# Web apps

Reviewer checks for this stack, read by projects that list it in
`harness/stacks.txt`. Each reviewer reads the section named for it. Checks for
this project's own recurring bugs belong in the reviewer's FILL THIS IN block,
not here — this file comes from the starter and `harness update` keeps it
current.

## reviewer-correctness

- **Rebuilt DOM.** Listeners, focus, scroll position and half-typed input lost
  when a region is re-rendered, or listeners attached twice when it is.
- **Stale closures.** A handler that captured a value before it changed.
- **Out-of-order responses.** An older fetch landing after a newer one and
  overwriting it.
- **Markup from data.** Values interpolated into `innerHTML` without escaping.
- **Browser storage.** `localStorage` and friends can throw or come back empty
  (private windows, blocked storage); a read that isn't guarded takes the page
  down.

## reviewer-taste

- **Native elements first.** A control built from `div`s where the browser
  already ships it (`<button>`, `<dialog>`, `<details>`, native inputs). The
  native one brings keyboard handling and accessibility with it.
- **Accessible names.** Icon-only controls carry an `aria-label` or visible
  text; everything clickable is reachable by keyboard, with a visible focus
  state.
- **Colours from tokens.** A colour literal in a rule, where the stylesheet
  already has a custom property for it, is drift waiting to happen.

## reviewer-design

- **Both themes.** If the app has a light and a dark theme, the captures
  should show the change in both.
- **Narrow widths.** A phone-width capture is where overflow and horizontal
  scroll show up.
- **Hover and focus.** The loud state is usually a hover or a focus ring;
  judge the geometry there.

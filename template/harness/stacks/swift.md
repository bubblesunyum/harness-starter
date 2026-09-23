# Swift and Apple platforms

Reviewer checks for this stack, read by projects that list it in
`harness/stacks.txt`. Each reviewer reads the section named for it. Checks for
this project's own recurring bugs belong in the reviewer's FILL THIS IN block,
not here — this file comes from the starter and `harness update` keeps it
current.

## reviewer-correctness

- **Concurrency.** Work touching main-actor state from another context, `Task`s
  whose lifetime exceeds the view or object that spawned them, captures that
  outlive what they captured.
- **Retain cycles.** A closure stored on `self` that captures `self` strongly;
  a delegate that isn't `weak`.
- **Optionals.** Force unwraps and `try!` on anything that can come from
  outside — a file, the network, user input.
- **Async.** A missing `await`, cancellation that is never checked, a refresh
  racing a user action.
- **Target membership.** A new source file that isn't in the target, or a
  resource that isn't in the bundle, builds fine and then fails at runtime.

## reviewer-taste

- **Stock controls first.** A control assembled from shapes and gestures where
  SwiftUI or UIKit already ships it. The stock one brings its accessibility
  and platform behavior with it.
- **Dynamic Type.** Semantic text styles (`.body`, `.headline`) over fixed
  point sizes, so text honors the reader's settings.
- **Accessibility labels.** Icon-only buttons carry an `accessibilityLabel`.

## reviewer-design

- **Size classes and platforms.** Where the screen renders on iPhone, iPad or
  Mac, the captures should show each one, recognisably the same design.
- **Large text.** A capture at an accessibility text size is where truncation
  hides.
- **Rows own their edges** applies to a `List` too: the insets belong on the
  row's content, not on the list.

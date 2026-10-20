# Color Picker

Picks colors anywhere on screen with the macOS loupe, keeps them, and writes
them out the way you paste them: HEX, RGB, HSL, OKLCH, LCH, Display P3, or
SwiftUI.

- **Pick Color** closes the launcher, shows the loupe, copies the color you
  click in your first format, and confirms it in a HUD. Escape cancels. Give
  it a hotkey to pick without opening Prism.
- **Colors** lists what you picked, newest first, with favorites on top and
  the closest CSS color name beside each. Return copies the first format;
  ⌘K copies any format that’s on, adds to or removes from Favorites (⌘⇧F),
  deletes (⌘⌫), or clears every color that isn’t a favorite (⌘⇧⌫). ⌘P shows
  only favorites. The detail pane shows every format.
- **Convert Color** reads a color you type or paste, such as `#FF6363`,
  `rgb(255 99 99)`, `hsl(0 100% 69%)`, `oklch(0.7 0.19 23)`,
  `color(display-p3 0.92 0.43 0.41)`, or `coral`, and lists it in every
  format. Typing part of a name finds the CSS named colors. ⌘S saves the
  color to Colors.

Colors sampled from a wide-gamut display keep their Display P3, OKLCH, and
LCH values; HEX, RGB, and HSL clamp them to sRGB.

## Setup

In Settings → Extensions → Color Picker, drag **Formats** into the order you
want and switch off the ones you never use. Pick Color copies the first.

Needs nothing beyond macOS and declares no capabilities: colors are kept in
Prism, and nothing leaves your Mac.

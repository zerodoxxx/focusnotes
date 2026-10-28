# Quick note: UI design

The ⌥⇧N panel, redesigned around one idea: **at rest it is only your words.**
Everything else appears when the pointer comes to it. The surface is near-black (light: near-white), the
caret and checkboxes carry one coral accent, and the only chrome that is always present is a faded title line.

## 1. Rest, hover, overlays

| State | What is visible |
| --- | --- |
| **Rest** (pointer outside the panel) | Text plus the **title line**, centred in the top band at 30% label colour. No buttons, no footer. Markdown headings are full strength. |
| **Hover** (pointer inside the panel) | The title brightens to 60%, five icon buttons fade in (two plain on the left, three in a capsule on the right), and a footer fades in with the controls. Nothing else changes. |
| **Actions** (⌘K) | A card hanging from the top-right corner, just under the band. The note stays visible behind it; chrome stays revealed. |
| **Browse** (⌘P) | The same kind of card, with a search field and a note list. The card has a bottom strip with its Browse hints; the note footer keeps its normal hints. |

Typing never reveals the chrome. Keyboard focus alone leaves the panel calm.

```
 rest                                   hover
┌──────────────────────────────┐       ┌──────────────────────────────┐
│        Trip planning         │       │ ✕ ⤢   Trip planning  (▭ + ⋯)│  top band, 38pt
│  Trip planning               │       │  Trip planning               │
│  Book the train for Friday   │       │  Book the train for Friday   │
│  - call Anna                 │       │  - call Anna                 │
│                              │       │ ⌘↩ Create note  ⌘K Actions   │  footer, 38pt
└──────────────────────────────┘       └──────────────────────────────┘
```

## 2. Structure

- Surface: the shared `OverlaySurface`, so the whole app has one look. The popover
  material stays underneath for a hint of depth; a full-bleed `surfaceTint` layer (dark #161616, light #FBFBFB,
  both at 97%) sits above it. Border: `surfaceBorder` 0.5pt (dark white 12%, light black 10%). Radius:
  `quickPanelRadius` 16 for the quick note (other overlays keep 14). Gallery snapshots fill the tint at 100%.
- Text inset: 20pt left/right. 38pt top band and 38pt bottom band are always
  reserved (the 18pt keycap row is centred in the bottom band), so revealing the chrome never moves the text.
- The old "In <note>" header stays removed. The note's name lives in the title line (below).

### Title line
A single line, centred in the 38pt top band, 13pt medium, truncating tail, never overlapping the
button groups (max width = band width − 2 × (widest group extent + 12)). It is visible at rest at
`labelColor` 30% and animates to 60% on reveal with the chrome's timing (0.15s ease-out in, 0.20s
ease-in out, instant with Reduce Motion). It does not take the mouse. Accessibility: a static text
whose value is the title. When pinned, a 10pt medium `pin.fill` appears before it with a 4pt gap
(`quickTitlePinSize`/`quickTitlePinGap`). Glyph and title are centred as one unit, share the 30%/60%
reveal alpha, and together respect the button clusters and title truncation.

Text rule: the destination title when a destination is set (session or chosen note); otherwise, once the text is
non-blank, the title of the existing note it will be added to or the title it will be saved under; otherwise "New
note", or "Folder: <folder>" for a quick note opened by a folder shortcut. A folder quick note resolves typed names
inside its folder, so its title, footer caption and Save as New Note follow the same rules as a standalone note. The saved-under title
comes from the host through `NoteEditorHandlers.titleForText` (the app passes `TypedNote(...).title`;
OverlayKit's default is the first non-blank line with leading Markdown markers stripped, cut at 60 characters).
It is recomputed on every text change (head of the note only) and on `setDestination`.

### Top band chrome (hover only; left to right)
- Left, plain: **Close** (`xmark`) and **Open as note** (`arrow.up.left.and.arrow.down.right`).
- Right, in ONE capsule (28pt high, 14pt radius, 1pt padding, fill `quickClusterFill`, 0.5pt `quickClusterBorder`,
  buttons adjacent): **Browse** (`rectangle.on.rectangle.angled`, falling back to `square.on.square`; ⌘P),
  **New** (`plus`, ⌘N), **Actions** (`ellipsis`, ⌘K) at the trailing edge. The action card hangs under
  the trailing Actions button; its tooltip and label remain "Actions (⌘K)" and "Actions".
- Each button is a 26×26 hit target with a 13pt medium symbol, 10pt from the band edges. Resting colour
  secondary label; hover: label colour on a circular `labelColor` 8% fill; pressed: 14%. Tooltips name the
  action and its shortcut. Every button has an accessibility label.
- While a card is open, its Actions or Browse button keeps the circular 14% pressed fill and label colour,
  including on hover. Its accessibility value is on and selected. Opening by click or shortcut, swapping cards,
  and every close path update this state; only the currently open card's button is on.
- The buttons and capsule fade with the reveal; the title line is separate and stays visible.

### Footer
Keycap hints only (existing `KeycapView`): `⌘↩ <save caption>`, `⌘K Actions`, `esc Close`.
Save caption: **"Add to note"** when a destination is set or the typed name resolves to an existing (or
reserved) note by the same rule saving uses (`NoteEditorHandlers.existingTitleForText`), **"Create note"**
otherwise (the title line already names the note, so the footer no longer repeats it).
Trailing, quiet: "Draft kept" when a draft was restored. Opening Browse keeps these normal note hints.
The Browse controls appear inside the floating card so they remain visible when it covers the note footer.

## 3. Size follows the note

- **Width** grows with the longest line: clamp(longest line + 24 indent allowance + 40,
  footer's natural width, 600), floor 400, and never shrinks while the panel is open
  (no jitter). The footer is never allowed to overlap itself: "Draft kept" is hidden
  first if the cap is reached. Grows symmetrically about the
  panel's centre.
- **Height** grows with the text: from two lines up to
  min(60% of the screen's visible height, 680pt). Beyond that the text scrolls
  with an auto-hiding scroller. The top edge stays fixed.
  Laid-out lines count once, including an empty trailing caret line. Body paragraphs use the same line
  height for lists, tasks, ordered lists, quotes, bold and inline code; headings may be taller. Adding
  lines grows the note and deleting them shrinks it back to the two-line minimum. Width keeps ratcheting.
  The last line has the same bottom spacing in every body style; the text document uses the same measured
  content height as the viewport, with no extra fragment added a second time.
- Resizes use the existing 0.12s ease-out animation, or none with Reduce Motion.

### Moving
The panel can be dragged by its **top band** (the title included, anywhere except the chrome buttons) and its
**footer band**, at rest or revealed. The text area (it selects text) and an open card are not handles; a band
click with a card open closes the card and still drags. After a drag the panel's top-centre is stored as
fractions of its screen's visible frame (`NoteEditorPanel.topCenter` in UserDefaults). The next ⌥⇧N opens with its
top-centre at those fractions of the screen the mouse is on, clamped fully inside that screen; with nothing stored
it uses the default position. Dragging onto another screen keeps the panel open (its height cap follows the new
screen). Screen-parameter changes re-clamp the note into its current screen instead of dismissing it.
Space changes keep it visible at the same level and position, including full-screen apps. Resizes keep the top edge fixed and grow about the
centre, but shift the minimum needed to stay inside the screen. Search, input and toasts are not movable.

### Sticky focus and closing
Quick notes are sticky by default, independently of whether a panel is movable. Clicking another app
never closes the note. Losing key closes an Actions/Browse card and restores the note text as the
window's first responder; the caret stops while the panel is not key and hover reveal still works.
The first click in text places the caret; the first click on a visible button runs it; a band drag moves
the panel immediately. These interactions borrow focus without activating focusnotes.

⌥⇧N while the note is visible but not key restores keyboard focus in the same window, preserving
text, caret and scroll. While key, ⌥⇧N closes it and keeps the draft. Explicit closes remain ⌘↩ save,
esc/✕, Open as Note, opening another focusnotes panel, and app quit. Input and Search keep their
existing dismiss-on-click-away and Space-change behaviour.

## 4. Cards (⌘K and ⌘P)

Actions and Browse are floating overlays in **one nonactivating window**. The note surface keeps its own size; the window extends transparently below it when a card needs more room.

- Shared surface: `cardFill` (dark #1E1E1E, light white, both opaque), 0.5pt `cardBorder`
  (white or black at 10%), radius 12, the existing soft menu shadow.
- Anchor: top-right, just under the band: x = note width − 8 − card width, y = 38 + 2. Opening, closing, filtering or
  swapping a card never resizes or moves the visible note, its title, text, chrome or footer. A card may hang below
  the note; the window grows downward with its top fixed to card bottom + 8pt and shrinks back to the note instantly.
  Extra space is fully transparent and the window shadow follows only the visible note/card shapes.
- Card height is capped to end at least 8pt above the screen visibleFrame bottom. Both Actions and Browse scroll
  internally when capped. The note never moves to make room. Text growth still resizes the note normally with the
  card anchored to it. Position memory, height caps, reveal tracking and drag handles use the note rect. Transparent
  overflow and cards are never drag handles; a click in transparent overflow passes through or closes the card.
- Opening one card closes the other. ⌘K and ⌘P toggle their own card. esc closes only the card. A click
  outside the card closes it. Chrome stays revealed while a card is open. The note text stays visible behind it.
- Shared header: a 36pt filter field (13pt, 12pt inset, "Search actions…" / "Search notes…") over a 0.5pt separator.
  Its insertion point is `brandAccent`; the first click focuses the field for typing even when another app is
  frontmost. Card backgrounds, rows and scroll documents also accept the first click without activating the agent.
- The pointer appears on the first movement after typing, even though the agent remains inactive. It is an arrow
  over bands, chrome and cards, and an I-beam over note text and filter fields. A rendered task checkbox (the click target that toggles it) shows the pointing hand; a raw marker keeps the I-beam. Hover selects an enabled row with
  the keyboard highlight; a click runs the Actions row or chooses Write here in Browse. Disabled Actions neither
  highlight nor run. Row labels and icons share the row hit target.
- Selected row: the quiet fill (`labelColor` at 8%), radius 6, 4pt inset from the card sides. Never the accent.

### Actions card (⌘K)
280pt wide. Rows are 32pt: 14pt symbol (secondary), 8pt gap, 13pt title, trailing keycaps: ONE
bordered box per key glyph (⇧ ⌘ P is three boxes; each at least 18×18, radius 4, 0.5pt border at 18%, 11pt
medium glyph, 3pt apart, 12pt from the card's right edge). Two groups divided by a separator.
↑/↓ move, ↩ runs, ⌘K or esc closes the card (not the panel).

| Group | Action | Shortcut | Notes |
| --- | --- | --- | --- |
| 1 | New Note | ⌘N | Saves the current text, then opens a blank note. With empty text it clears the chosen destination and restores session routing. |
| 1 | Write outside session | ⇧⌘N | Shown only with an active session. Toggles standalone routing for this note; choosing it again restores the session destination. |
| 1 | Save as New Note | ⌥⌘↩ | Creates a numbered note when a standalone title names an existing note, including while writing outside a session. Disabled for an explicit Browse or session destination. |
| 1 | Add to Pinned / Remove from Pinned | ⇧⌘P | Adds/removes a note in Browse’s Pinned section. This does not control the window. For an unsaved draft, the intent persists with the draft and pins its created note on save. |
| 2 | Open as Note | ⌘O | The maximise action (see §6). |
| 2 | Copy as Markdown | ⇧⌘C | Copies the text. |
| 2 | Discard Draft | ⇧⌘⌫ | Clears the text and draft. Disabled when empty. |

Rows that do not apply are dimmed (40%) and skipped by the arrow keys. Browse lives in the top-right capsule;
⌘P still opens it from the editor and swaps Actions to Browse while the filter is focused.
Write outside session keeps the text and active session. The title uses the resolved standalone
note name and the footer uses the usual Create note/Add to note state; typed folder and `/` home
paths, Browse, and pin-on-save work as for a standalone note. Saving or closing clears the transient
choice, like a Browse destination, while closing keeps the draft text. The next quick note or ordinary
capture returns to the session. A successful outside-session toast names the destination and the
still-active session.
The unsaved pin intent survives esc, ✕ and toggle-close, is consumed on save, and is cleared by
Discard Draft or New Note resetting the destination. An existing/session destination uses its real pin state.
Interactive saves, shutdown retries and startup journal replay share one post-commit step: apply the pin after
the note write succeeds and before consuming the draft. Interactive saves use that call's intent; recovery uses
the latest intent in the matching persisted draft. Clearing the intent before recovery leaves the note unpinned.
Intent is not copied into the journal: a discarded or replaced draft cannot supply an old job's pin, and a job
remaining after draft cleanup has already passed the pin step.
If pin storage fails, the save still succeeds and clears the draft. Show exactly one warning toast instead of the
success toast: "Note saved, but not pinned", with the note's destination title as its subtitle. The panel closes normally.

## 5. Browse card (⌘P)

320pt wide, anchored like the Actions card (it replaces the old 520×380 takeover). A 36pt search field
("Search notes…") sits over a separator, then a list in two sections, **Pinned** then **Recent** (sentence-case
11pt medium tertiary headers, 24pt tall, 12pt leading, no tracking). At most seven rows are visible; past that the
list scrolls with an auto-hiding scroller. Rows are 40pt: 14pt symbol (`record.circle` for sessions, `doc.text`
for notes) at 12pt leading, 10pt gap, 13pt medium title above 11pt secondary detail ("Session · Oct 9", 2pt
gap), and a trailing 9pt `pin.fill` when pinned. The inbox is not listed. Typing filters by title. Empty list:
"No notes yet". No matches: "No matching notes" (13pt secondary, centred, 56pt area above the hint strip).

| Key | Does |
| --- | --- |
| ↩ or click | **Write here**: the next save appends to this note. Closes the card; the title line shows the note. |
| ⌘↩ | Open the note in the default Markdown app. |
| ⌥↩ | Reveal in Finder. |
| esc or ⌘P | Close the card (not the panel). |

The card has a **28pt bottom hint strip** (`browseFooterHeight`) with a 0.5pt separator above it. It uses
the existing `KeycapView` style: `↩ Write here`, `⌘↩ Open`, `⌥↩ Reveal`, starting 12pt from the left
(`browseFooterInset`) with `footerHintGap` between hints. The strip and separator count toward card height
and the screen cap; the list scrolls above them and the strip remains visible when the card is capped.
The note footer always keeps its normal hints. A screen change recomputes the card cap from the new
visible frame while preserving the note frame and card anchor when the note already fits.

## 6. Open as note (maximise)

"A bigger screen" is the user's default Markdown app, in the same Obsidian-compatible
vault: the text is saved exactly as ⌘↩ would save it (to the chosen Browse destination,
the active session unless Write outside session is selected, or the title-derived note), then that note opens. With no text,
it opens the chosen destination or the session note when session routing applies; with neither, a toast
says "Nothing to open yet". An in-app note window is a possible follow-up.

## 7. Colour and type

- Body text: existing editor fonts (15pt, 1.25 line height). Placeholder "Start writing…" (tertiary).
- Headings: existing sizes (22/19/17/15 semibold) in full `labelColor`. The faded line is the title line, not the headings.
- Brand accent (`brandAccent`): dark #FF6B5F, light #E5483C. Used for the caret and checkboxes only
  (unchecked: 1.5pt stroke; checked: fill with a white check; box 13pt, radius 3.5).
- Caret: 2pt wide, 1pt radius, `brandAccent`. Its height follows the font at the caret, not the line
  fragment: 1.1 × point size (16.5pt in body text), bottom 0.22 × point size below the baseline. The real
  caret is drawn by overriding `NSTextView.drawInsertionPoint(in:color:turnedOn:)` (macOS 14+ does not use
  `NSTextInsertionIndicator` for this TextKit 1 view), widening invalidation to cover it; gallery snapshots
  use the same geometry (`NoteTextView.tightCaretRect(forSystemRect:)`). The line (and x) come from the rect AppKit
  supplies, so at a soft wrap the bar sits on the line the system draws on; an empty line inside an open code fence
  is sized for the code font. A selection draws no caret; marked (IME) text keeps its caret. The insertion-point
  screen geometry reported through `firstRect(forCharacterRange:actualRange:)` uses the same tight caret so
  system input-source/Caps Lock accessories anchor to it.
- Chrome and footer: `secondaryLabelColor` symbols, existing hint fonts.
- Every colour is dynamic (light and dark) via `NSColor(name:dynamicProvider:)` or semantic label colours.

## 8. Motion

| Thing | Duration | Curve |
| --- | --- | --- |
| Chrome and title reveal | 0.15s | ease-out |
| Chrome and title hide | 0.20s | ease-in |
| Action / Browse card open, close, swap | instant | none |
| Panel resize | 0.12s | ease-out (existing) |

Reduce Motion: all of the above are instant. No timers run while idle; the
pointer-exit hide is a one-shot animation, not a poll.

## 9. Accessibility

Every icon button has an accessibility label and a tooltip. Overlay rows are
accessibility buttons (as in search). Contrast uses system label colours only.
Keyboard: every action has a shortcut; Tab is untouched in the editor.

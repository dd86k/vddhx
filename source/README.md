# Internals

Notes for working on the source. Each module's header comment carries the detail;
this is the map and the handful of things that span modules.

## Modules

| File | What it holds |
| --- | --- |
| `main.d` | SDL setup, event loop, key routing |
| `ui.d` | documents, views, panes, tabs, and every command |
| `hexview.d` | the hex panel widget: grid, caret, minimap, edit hooks |
| `split.d` | pane layout arithmetic |
| `tabbar.d` | tab strip, drag and reorder |
| `omnibar.d` | the omnibar and its modes |
| `search.d` | pattern parsing and document scanning |
| `address.d` | offset expression parsing |
| `bookmarks.d` | bookmark list and edit shifting |
| `menu.d` | menubar widgets (candidates for ddui itself) |
| `render.d` | SDL3_ttf text engine and font faces |
| `loader.d` | opens the SDL3 shared libraries (dynamic build only) |
| `about.d`, `uitext.d` | About dialog, text helpers |
| `screenshot.d` | debug frame capture (`-b screenshot`) |

## Frame

`main` owns the loop; `ui_frame` is the whole UI, once per frame:

```
mu_begin(ctx) -> ui_frame(ctx, w, h) -> mu_end(ctx) -> render_commands(renderer, ctx)
```

ddui is immediate mode, so nothing is retained between frames but the state
modules hold themselves. Two consequences worth knowing before touching the
loop:

- **The loop sleeps.** Idle frames are not drawn: `SDL_WaitEvent` blocks until
  something arrives, then `FRAMES_PER_INPUT` frames are drawn and it sleeps
  again. One frame is not enough, because a click that opens a popup or moves
  focus only reaches the screen on the frame after the one that read it. Any new
  path that changes the screen without an SDL event has to push one - that is
  what `ui_wakeup` is for, and how the async file dialogs get themselves drawn.
- **Command replay order.** `render_commands` walks the command list with
  `mu_get_next_command`, not `mu_command_range`. The former follows the jumps
  ddui writes to splice containers into z-order; the latter walks raw and draws
  popups behind the content they sit over.

## Ownership

All application state is three module globals in `ui.d`:

```
docs[]      every open document
columns[]   the grid of panes
focused     the pane taking the keyboard
```

Those are two separate structures, joined by `View.doc`. The grid nests; the
document list is flat:

```
Column        a share of the window's width              columns[]
  Pane        a tab strip over one hex panel             .panes[]
    View      caret, scroll, entry mode, diff pairing    .views[] (.current is the front tab)
      \-----> Document   bytes, path, title, bookmarks   docs[]
```

So a document does not know what is looking at it, and several views can point at
one: that is what puts the same file in two panes at different offsets. Closing a
tab closes a view; the document outlives it until its last view goes.

Every level is held by pointer, never by value, because the hex panel's callbacks park a `Document*`
and a `View*` for ddui to hand back on every read, colour and edit, and those
have to survive their neighbours closing. A pane is likewise named by its pointer
everywhere, so splitting or closing elsewhere in the grid cannot silently turn a
reference to one pane into a reference to another.

The grid is two levels deep and no deeper - a row of columns, a stack of panes
per column - rather than a tree. That covers side-by-side and stacked splits with
two passes of flat arithmetic (`split.d`) and leaves no interior node holding one
child.

None of `docs`, `columns`, or a pane's `views` is ever empty: startup opens a
scratch buffer, closing the last tab leaves a fresh one, and a pane that empties
is closed unless it is the last. So every command can assume it has a pane, a
view and a document.

## The hex panel

`hexview.d` knows nothing about ddhx or about `ui.d`. Everything outside the grid
arrives as a function pointer plus a user pointer: `HexReadFn` for bytes,
`HexColorFn` / `HexBackFn` / `HexBackSpanFn` for tinting, `HexReplaceFn` /
`HexInsertFn` / `HexRemoveFn` / `HexUndoFn` / `HexRedoFn` for editing. A panel
with no write hooks is read-only; one with no read hook draws its `data` slice.
That is what lets the panel be unit-tested against a plain array, and what makes
the diff colouring a hook rather than a mode.

Scrolling is tracked in **rows, not pixels**, so a multi-gigabyte file cannot
overflow the offset, and rows are virtualised: only what is on screen is ever
read.

`hex_split` copies a panel onto the same bytes for a new pane. It is not a struct
copy - the per-frame scratch buffers are dropped so the two panels do not draw
through each other's, and the hooks come across carrying the *source* view's user
pointers, so the caller must repoint them before the new panel draws.

## Keys

ddui's `MU_KEY_*` bits stop at `1 << 5`; `hexview.d` continues from `1 << 6`
(`HEX_KEY_*`) so caret keys ride the same `ctx.key_down` bitmask. `main.d` does
the mapping.

Two rules in the routing:

- The omnibar takes the keyboard when it is open (`ui_omni_active`), since it
  wants text where the panel wants hex digits and chords.
- Punctuation shortcuts bind to **typed characters, not keycodes** - a `[` is not
  at a fixed position on every layout.

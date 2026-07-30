/// Splitter bar and the geometry behind a line of panes.
///
/// ddui has no split container, but a line of them needs very little: the panes
/// are laid out from a weight each, a grab bar sits between every pair, and
/// dragging one moves weight across that boundary. There is no tree here on
/// purpose - the caller stacks these lines at most two deep, columns across the
/// window and panes down a column - so a pane is an index and one line of them is
/// two int arrays.
///
/// The geometry knows nothing of which way the line runs: it shares a count of
/// pixels out and takes a count back, so the same two functions serve a row of
/// columns and a column of panes. Only the bar has an axis, since it has to be
/// drawn and has to read one half of the pointer's movement: hence split_bar_x
/// for a boundary that moves left and right, split_bar_y for one that moves up
/// and down.
///
/// The geometry is kept apart from the drawing so it can be reasoned about (and
/// tested) without a context: see split_layout and split_resize.
/// Authors: dd
module split;

import core.stdc.string : strlen;
import ddui;

/// Width of a splitter bar, and so the gap between two panes.
enum int SPLIT_WIDTH = 6;

/// The weight a pane is born with. Weights are relative, so the number only sets
/// how finely a drag can divide the space: a boundary moved by one pixel shifts
/// weight by about `avail / SPLIT_WEIGHT` of a unit, and at 1000 a pane can be
/// resized a fraction of a pixel at a time without the arithmetic going flat.
enum int SPLIT_WEIGHT = 1000;

private enum mu_Color SPLIT_IDLE  = mu_Color( 30,  30,  38, 255);
private enum mu_Color SPLIT_HOVER = mu_Color( 70,  70,  85, 255);
private enum mu_Color SPLIT_HELD  = mu_Color(110, 170, 255, 255);

/// Draw an upright splitter bar in `r` and report what the pointer did to it.
///
/// The boundary between two panes side by side, so it moves left and right.
/// Params:
///     ctx = ddui context.
///     name = Stable id string, unique among sibling widgets.
///     r = Where the bar goes, normally SPLIT_WIDTH wide and a pane tall.
/// Returns: Pixels the pointer moved it this frame, 0 when it is not being
///          dragged. Positive is rightwards: the pane on the left grows.
int split_bar_x(mu_Context* ctx, const(char)* name, mu_Rect r)
{
    return split_bar(ctx, name, r, true);
}

/// Draw a lying-down splitter bar in `r` and report what the pointer did to it.
///
/// The boundary between two panes stacked one over the other, so it moves up and
/// down.
/// Params:
///     ctx = ddui context.
///     name = Stable id string, unique among sibling widgets.
///     r = Where the bar goes, normally SPLIT_WIDTH tall and a pane wide.
/// Returns: Pixels the pointer moved it this frame, 0 when it is not being
///          dragged. Positive is downwards: the pane above grows.
int split_bar_y(mu_Context* ctx, const(char)* name, mu_Rect r)
{
    return split_bar(ctx, name, r, false);
}

/// Both of the above. The bar holds focus while dragged, so a fast drag that
/// outruns the pointer does not drop the bar the moment the cursor leaves it -
/// and only the movement along its own axis counts, so wandering across the bar
/// while dragging it does not feed the other axis in.
private int split_bar(mu_Context* ctx, const(char)* name, mu_Rect r, bool alongX)
{
    mu_Id id = mu_get_id(ctx, name, cast(int) strlen(name));
    mu_update_control(ctx, id, r, MU_OPT_HOLDFOCUS);

    bool held = ctx.focus == id && (ctx.mouse_down & MU_MOUSE_LEFT) != 0;
    mu_draw_rect(ctx, r, held ? SPLIT_HELD :
                         ctx.hover == id ? SPLIT_HOVER : SPLIT_IDLE);

    if (held == false)
        return 0;
    return alongX ? ctx.mouse_delta.x : ctx.mouse_delta.y;
}

/// Share `avail` pixels out over `weights`, writing one size per pane.
///
/// The last pane takes whatever integer division left over, so the sizes always
/// add back up to `avail` exactly and a line of panes never leaves a seam of bare
/// window along its far edge.
/// Params:
///     weights = One relative weight per pane. All-zero shares evenly.
///     avail = Pixels the panes have between them, the splitters excluded.
///     sizes = Filled in with a size per pane, along the line. Same length as
///             `weights`.
void split_layout(const(int)[] weights, int avail, int[] sizes)
{
    assert(sizes.length >= weights.length);
    if (weights.length == 0)
        return;

    long total;
    foreach (int w; weights)
        total += w;

    // No weights to go on (a pane row built by hand, say): an even share is a
    // better answer than a division by zero.
    if (total <= 0)
    {
        int even = avail / cast(int) weights.length;
        sizes[0 .. weights.length] = even;
        sizes[weights.length - 1] = avail - even * (cast(int) weights.length - 1);
        return;
    }

    int used;
    foreach (size_t i, int w; weights[0 .. $ - 1])
    {
        sizes[i] = cast(int)((cast(long) avail * w) / total);
        used += sizes[i];
    }
    sizes[weights.length - 1] = avail - used;
}

unittest
{
    int[4] got;

    // Even weights divide evenly.
    static immutable int[2] two = [ 1000, 1000 ];
    split_layout(two, 800, got);
    assert(got[0 .. 2] == [ 400, 400 ]);

    // Uneven ones divide in proportion.
    static immutable int[2] third = [ 1000, 2000 ];
    split_layout(third, 900, got);
    assert(got[0 .. 2] == [ 300, 600 ]);

    // The remainder of an inexact division lands on the last pane rather than
    // being dropped: three panes over 800px is 266.67 each.
    static immutable int[3] three = [ 1000, 1000, 1000 ];
    split_layout(three, 800, got);
    assert(got[0 .. 3] == [ 266, 266, 268 ]);
    assert(got[0] + got[1] + got[2] == 800);

    // One pane takes the lot.
    static immutable int[1] one = [ 1000 ];
    split_layout(one, 640, got);
    assert(got[0] == 640);

    // Weights nobody set: an even share, remainder still on the last.
    static immutable int[3] zero = [ 0, 0, 0 ];
    split_layout(zero, 100, got);
    assert(got[0 .. 3] == [ 33, 33, 34 ]);

    // A large window does not overflow the arithmetic on the way through.
    static immutable int[2] big = [ 1000, 1000 ];
    split_layout(big, 32000, got);
    assert(got[0 .. 2] == [ 16000, 16000 ]);
}

/// Move the boundary between panes `at` and `at + 1` by `dx` pixels.
///
/// Only those two weights change and their sum is kept, so the panes either side
/// trade space and nothing else on the line moves. The drag is clamped so neither
/// falls below `minPx`, which is what stops a pane being shrunk to nothing and
/// lost: a pane already at the floor simply refuses to give any more.
/// Params:
///     weights = One weight per pane, edited in place.
///     at = The boundary, counted by the pane before it.
///     dx = Pixels to move it by, positive towards the end of the line.
///     avail = Pixels the panes have between them, as passed to split_layout.
///     minPx = Smallest a pane may become.
/// Returns: The pixels actually moved, which is `dx` less whatever the clamp took.
int split_resize(int[] weights, size_t at, int dx, int avail, int minPx)
{
    if (at + 1 >= weights.length || dx == 0 || avail <= 0)
        return 0;

    long total;
    foreach (int w; weights)
        total += w;
    if (total <= 0)
        return 0;

    // Where the two panes stand now, in pixels, so the clamp can be expressed in
    // what the user is actually looking at.
    int before = cast(int)((cast(long) avail * weights[at])     / total);
    int after  = cast(int)((cast(long) avail * weights[at + 1]) / total);

    // Neither may cross the floor. With both already under it - a window too
    // small for the panes in it - the room to give is nil rather than negative.
    int room = before - minPx;
    if (room < 0) room = 0;
    int give = after - minPx;
    if (give < 0) give = 0;
    if (dx < -room) dx = -room;
    if (dx > give)  dx = give;
    if (dx == 0)
        return 0;

    // Back into weights. The pair's total is preserved exactly, so repeated drags
    // cannot leak weight out of the line.
    int sum = weights[at] + weights[at + 1];
    weights[at] = cast(int)((cast(long)(before + dx) * total) / avail);
    if (weights[at] > sum) weights[at] = sum;
    if (weights[at] < 0)   weights[at] = 0;
    weights[at + 1] = sum - weights[at];
    return dx;
}

unittest
{
    // Two even panes over 800px: 400 each. Dragging the boundary 100px right
    // makes it 500/300, and the weights say the same.
    int[2] w = [ 1000, 1000 ];
    assert(split_resize(w, 0, 100, 800, 100) == 100);
    int[4] got;
    split_layout(w, 800, got);
    assert(got[0 .. 2] == [ 500, 300 ]);
    assert(w[0] + w[1] == 2000); // the pair's weight is conserved

    // And back again.
    assert(split_resize(w, 0, -100, 800, 100) == -100);
    split_layout(w, 800, got);
    assert(got[0 .. 2] == [ 400, 400 ]);

    // The floor stops the drag part way: the right pane can only give 300 of the
    // 500 asked for before it would go under 100px.
    int[2] floored = [ 1000, 1000 ];
    assert(split_resize(floored, 0, 500, 800, 100) == 300);
    split_layout(floored, 800, got);
    assert(got[0 .. 2] == [ 700, 100 ]);

    // Once there, it gives nothing more, and the widths hold.
    assert(split_resize(floored, 0, 50, 800, 100) == 0);
    split_layout(floored, 800, got);
    assert(got[0 .. 2] == [ 700, 100 ]);

    // But it can still be taken back the other way.
    assert(split_resize(floored, 0, -200, 800, 100) == -200);
    split_layout(floored, 800, got);
    assert(got[0 .. 2] == [ 500, 300 ]);

    // A boundary in the middle of three leaves the third pane alone.
    int[3] mid = [ 1000, 1000, 1000 ];
    assert(split_resize(mid, 1, 60, 900, 100) == 60);
    split_layout(mid, 900, got);
    assert(got[0] == 300);          // untouched
    assert(got[1] + got[2] == 600); // the pair traded between themselves

    // Nonsense asks are refused rather than corrupting the row.
    int[2] safe = [ 1000, 1000 ];
    assert(split_resize(safe, 1, 50, 800, 100) == 0);  // no pane to the right
    assert(split_resize(safe, 0, 0,  800, 100) == 0);  // going nowhere
    assert(split_resize(safe, 0, 50, 0,   100) == 0);  // no room to speak of
    assert(safe == [ 1000, 1000 ]);

    // A window already too narrow for its panes: the drag is refused, not
    // allowed to make the squeeze worse.
    int[2] tight = [ 1000, 1000 ];
    assert(split_resize(tight, 0, 40, 100, 100) == 0);
}

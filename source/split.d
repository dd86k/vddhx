/// Splitter bar and the geometry behind a line of panes.
///
/// There is no tree here on purpose - the caller stacks these lines at most two
/// deep, columns across the window and panes down a column - so a pane is an
/// index and one line of them is two int arrays.
///
/// The geometry (split_layout, split_resize) knows nothing of which way the line
/// runs, so the same two functions serve a row of columns and a column of panes,
/// and it can be tested without a context. Only the bar has an axis, having to be
/// drawn and to read one half of the pointer's movement.
/// Authors: dd86k <dd@dax.moe>
module split;

import core.stdc.string : strlen;
import ddui;

/// Width of a splitter bar, and so the gap between two panes.
enum int SPLIT_WIDTH = 6;

/// The weight a pane is born with. Weights being relative, the number only sets
/// how finely a drag can divide the space; 1000 is fine enough that a pixel of
/// drag never rounds away.
enum int SPLIT_WEIGHT = 1000;

private enum mu_Color SPLIT_IDLE  = mu_Color( 30,  30,  38, 255);
private enum mu_Color SPLIT_HOVER = mu_Color( 70,  70,  85, 255);
private enum mu_Color SPLIT_HELD  = mu_Color(110, 170, 255, 255);

/// Draw an upright splitter bar in `r` - the boundary between two panes side by
/// side - and report what the pointer did to it. `name` is a stable id string.
/// Returns: Pixels the pointer moved it this frame, 0 when it is not being
///          dragged. Positive is rightwards: the pane on the left grows.
int split_bar_x(mu_Context* ctx, const(char)* name, mu_Rect r)
{
    return split_bar(ctx, name, r, true);
}

/// Draw a lying-down splitter bar in `r` - the boundary between two panes stacked
/// one over the other - and report what the pointer did to it.
/// Returns: Pixels the pointer moved it this frame, 0 when it is not being
///          dragged. Positive is downwards: the pane above grows.
int split_bar_y(mu_Context* ctx, const(char)* name, mu_Rect r)
{
    return split_bar(ctx, name, r, false);
}

/// Both of the above. The bar holds focus while dragged, so a fast drag that
/// outruns the pointer does not drop it the moment the cursor leaves.
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

/// What dropping something on a pane would do with it.
enum SplitZone
{
    centre, /// Put it in the pane itself, alongside what is already there.
    left,   /// Split the pane: the newcomer takes a new pane on that side.
    right,  /// Ditto.
    up,     /// Ditto, above.
    down,   /// Ditto, below.
}

// The zone test in fixed point: distances to the four edges are thousandths of
// the pane's own width and height, so a tall narrow pane and a short wide one
// offer the same share of themselves as an edge.
private enum int ZONE_SCALE = 1000;
private enum int ZONE_EDGE  = ZONE_SCALE / 3;

/// Which part of pane `r` (window coordinates) the point `p` is in, and so what a
/// drop there means.
///
/// The outer third along each axis splits the pane on that side and the middle
/// takes the drop whole. A corner belongs to whichever edge it is nearest in
/// proportion, so the two zones meet on the diagonal rather than one axis quietly
/// winning every corner.
///
/// The `headH` pixels off the top - a tab strip, 0 for a pane without one - are
/// centre throughout: dropping a tab on a row of tabs is joining that row, and a
/// strip's own top third would be a pixel or two of hair trigger.
/// Returns: The zone `p` falls in, centre for anything outside `r`.
SplitZone split_zone(mu_Rect r, int headH, mu_Vec2 p)
{
    mu_Rect inner = mu_Rect(r.x, r.y + headH, r.w, r.h - headH);
    if (inner.w <= 0 || inner.h <= 0)
        return SplitZone.centre;
    if (p.x < inner.x || p.x >= inner.x + inner.w ||
        p.y < inner.y || p.y >= inner.y + inner.h)
        return SplitZone.centre;

    int fx = (p.x - inner.x) * ZONE_SCALE / inner.w;
    int fy = (p.y - inner.y) * ZONE_SCALE / inner.h;

    int[4] dist = [ fx, ZONE_SCALE - fx, fy, ZONE_SCALE - fy ];
    static immutable SplitZone[4] zones =
        [ SplitZone.left, SplitZone.right, SplitZone.up, SplitZone.down ];

    size_t near;
    foreach (size_t i, int d; dist[1 .. $])
        if (d < dist[near])
            near = i + 1;
    return dist[near] < ZONE_EDGE ? zones[near] : SplitZone.centre;
}

unittest
{
    // A 300x300 pane at the origin, no strip.
    static immutable mu_Rect r = mu_Rect(0, 0, 300, 300);
    assert(split_zone(r, 0, mu_Vec2(150, 150)) == SplitZone.centre);
    assert(split_zone(r, 0, mu_Vec2(150,  50)) == SplitZone.up);
    assert(split_zone(r, 0, mu_Vec2(150, 250)) == SplitZone.down);
    assert(split_zone(r, 0, mu_Vec2( 50, 150)) == SplitZone.left);
    assert(split_zone(r, 0, mu_Vec2(250, 150)) == SplitZone.right);

    // Just inside and just outside the top boundary.
    assert(split_zone(r, 0, mu_Vec2(150,  99)) == SplitZone.up);
    assert(split_zone(r, 0, mu_Vec2(150, 100)) == SplitZone.centre);

    // Corners go to the nearer edge, the diagonal itself to the first of the two.
    assert(split_zone(r, 0, mu_Vec2(10, 40)) == SplitZone.left);
    assert(split_zone(r, 0, mu_Vec2(40, 10)) == SplitZone.up);
    assert(split_zone(r, 0, mu_Vec2(290, 20)) == SplitZone.right);
    assert(split_zone(r, 0, mu_Vec2(280, 10)) == SplitZone.up);

    // Zones below a strip are measured from its underside, not the pane's top.
    static immutable mu_Rect capped = mu_Rect(0, 0, 300, 320);
    assert(split_zone(capped, 20, mu_Vec2(150,  0)) == SplitZone.centre);
    assert(split_zone(capped, 20, mu_Vec2( 10, 10)) == SplitZone.centre);
    assert(split_zone(capped, 20, mu_Vec2(150, 25)) == SplitZone.up);
    assert(split_zone(capped, 20, mu_Vec2(150, 170)) == SplitZone.centre);

    // Offset panes work in window coordinates, not their own.
    static immutable mu_Rect away = mu_Rect(500, 400, 300, 300);
    assert(split_zone(away, 0, mu_Vec2(650, 550)) == SplitZone.centre);
    assert(split_zone(away, 0, mu_Vec2(550, 550)) == SplitZone.left);
    assert(split_zone(away, 0, mu_Vec2(650, 450)) == SplitZone.up);

    // A pointer that is not in the pane at all is nobody's edge.
    assert(split_zone(away, 0, mu_Vec2(0, 0))     == SplitZone.centre);
    assert(split_zone(away, 0, mu_Vec2(800, 550)) == SplitZone.centre);

    // A pane with nothing under its strip cannot be split into.
    static immutable mu_Rect flat = mu_Rect(0, 0, 300, 20);
    assert(split_zone(flat, 20, mu_Vec2(150, 10)) == SplitZone.centre);
}

/// The half of `r` a drop in `zone` would land in, for painting where it goes.
/// The whole of it for the centre, which is the whole pane taking the drop.
mu_Rect split_zone_rect(mu_Rect r, SplitZone zone)
{
    final switch (zone)
    {
    case SplitZone.centre: return r;
    case SplitZone.left:   return mu_Rect(r.x, r.y, r.w / 2, r.h);
    case SplitZone.right:  return mu_Rect(r.x + r.w / 2, r.y, r.w - r.w / 2, r.h);
    case SplitZone.up:     return mu_Rect(r.x, r.y, r.w, r.h / 2);
    case SplitZone.down:   return mu_Rect(r.x, r.y + r.h / 2, r.w, r.h - r.h / 2);
    }
}

unittest
{
    static immutable mu_Rect r = mu_Rect(10, 20, 100, 60);
    assert(split_zone_rect(r, SplitZone.centre) == r);
    assert(split_zone_rect(r, SplitZone.left)   == mu_Rect(10, 20, 50, 60));
    assert(split_zone_rect(r, SplitZone.right)  == mu_Rect(60, 20, 50, 60));
    assert(split_zone_rect(r, SplitZone.up)     == mu_Rect(10, 20, 100, 30));
    assert(split_zone_rect(r, SplitZone.down)   == mu_Rect(10, 50, 100, 30));

    // The far half takes the spare pixel of an odd size, the way a pane laid out
    // there would (see split_layout), so there is no seam and no overhang.
    static immutable mu_Rect odd = mu_Rect(0, 0, 101, 61);
    assert(split_zone_rect(odd, SplitZone.left)  == mu_Rect(0, 0, 50, 61));
    assert(split_zone_rect(odd, SplitZone.right) == mu_Rect(50, 0, 51, 61));
    assert(split_zone_rect(odd, SplitZone.up)    == mu_Rect(0, 0, 101, 30));
    assert(split_zone_rect(odd, SplitZone.down)  == mu_Rect(0, 30, 101, 31));
}

/// Share `avail` pixels (the splitters excluded) out over `weights`, writing one
/// size per pane into `sizes`. All-zero weights share evenly.
///
/// The last pane takes whatever integer division left over, so the sizes add back
/// up to `avail` exactly and a line never leaves a seam of bare window at its end.
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
        sizes[weights.length - 1] = avail - even * (cast(int) weights.length - 1); // @suppress(dscanner.suspicious.length_subtraction)
        return;
    }

    int used;
    foreach (size_t i, int w; weights[0 .. $ - 1])
    {
        sizes[i] = cast(int)((cast(long) avail * w) / total);
        used += sizes[i];
    }
    sizes[weights.length - 1] = avail - used; // @suppress(dscanner.suspicious.length_subtraction)
}

unittest
{
    int[4] got;

    static immutable int[2] two = [ 1000, 1000 ];
    split_layout(two, 800, got);
    assert(got[0 .. 2] == [ 400, 400 ]);

    static immutable int[2] third = [ 1000, 2000 ];
    split_layout(third, 900, got);
    assert(got[0 .. 2] == [ 300, 600 ]);

    // The remainder of an inexact division lands on the last pane rather than
    // being dropped: three panes over 800px is 266.67 each.
    static immutable int[3] three = [ 1000, 1000, 1000 ];
    split_layout(three, 800, got);
    assert(got[0 .. 3] == [ 266, 266, 268 ]);
    assert(got[0] + got[1] + got[2] == 800);

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

/// Move the boundary between panes `at` and `at + 1` by `dx` pixels, positive
/// towards the end of the line, editing `weights` in place. `avail` is as passed
/// to split_layout.
///
/// Only those two weights change and their sum is kept, so the panes either side
/// trade space and nothing else on the line moves. Neither may fall below `minPx`,
/// which is what stops a pane being shrunk to nothing and lost.
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

    // Where the two stand now in pixels, so the clamp reads in what the user is
    // actually looking at.
    int before = cast(int)((cast(long) avail * weights[at])     / total);
    int after  = cast(int)((cast(long) avail * weights[at + 1]) / total);

    // With both already under the floor - a window too small for the panes in it -
    // the room to give is nil rather than negative.
    int room = before - minPx;
    if (room < 0) room = 0;
    int give = after - minPx;
    if (give < 0) give = 0;
    if (dx < -room) dx = -room;
    if (dx > give)  dx = give;
    if (dx == 0)
        return 0;

    // Back into weights, preserving the pair's total exactly so repeated drags
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
    // Two even panes over 800px: dragging the boundary 100px right makes it
    // 500/300, and the weights say the same.
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

    // A window already too narrow for its panes: refused rather than allowed to
    // make the squeeze worse.
    int[2] tight = [ 1000, 1000 ];
    assert(split_resize(tight, 0, 40, 100, 100) == 0);
}

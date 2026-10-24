/// Splitter bars and pane line geometry.
///
/// No tree: the caller nests at most two levels (columns, then panes per
/// column), so a line is two int arrays. split_layout/split_resize are
/// axis-agnostic and testable without a context; only the bar has an axis.
/// Authors: dd86k <dd@dax.moe>
module split;

import core.stdc.string : strlen;
import ddui;

/// Splitter bar width, the gap between panes.
enum int SPLIT_WIDTH = 6;

/// Initial pane weight. Weights are relative; 1000 is fine enough that a 1px
/// drag never rounds away.
enum int SPLIT_WEIGHT = 1000;

private enum mu_Color SPLIT_IDLE  = mu_Color( 30,  30,  38, 255);
private enum mu_Color SPLIT_HOVER = mu_Color( 70,  70,  85, 255);
private enum mu_Color SPLIT_HELD  = mu_Color(110, 170, 255, 255);

/// Vertical splitter bar between side-by-side panes. `name` is a stable id.
/// Returns: Pixels dragged this frame, 0 if not dragging. Positive: rightwards.
int split_bar_x(mu_Context* ctx, const(char)* name, mu_Rect r)
{
    return split_bar(ctx, name, r, true);
}

/// Horizontal splitter bar between stacked panes.
/// Returns: Pixels dragged this frame, 0 if not dragging. Positive: downwards.
int split_bar_y(mu_Context* ctx, const(char)* name, mu_Rect r)
{
    return split_bar(ctx, name, r, false);
}

/// Holds focus while dragged so fast drags don't lose it.
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

/// Drop target within a pane.
enum SplitZone
{
    centre, /// Into the pane.
    left,   /// Split, new pane on that side.
    right,
    up,
    down,
}

// Fixed point, relative to pane size, so edges are the same share for any
// aspect ratio.
private enum int ZONE_SCALE = 1000;
private enum int ZONE_EDGE  = ZONE_SCALE / 3;

/// Zone of pane `r` (window coordinates) containing `p`.
///
/// Outer thirds split on that side, the middle is centre. Corners go to the
/// proportionally nearer edge (split on the diagonal). The top `headH` pixels
/// (tab strip, 0 if none) are always centre: dropping on tabs joins them.
/// Returns: The zone; centre if outside `r`.
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
    // 300x300 at origin, no strip.
    static immutable mu_Rect r = mu_Rect(0, 0, 300, 300);
    assert(split_zone(r, 0, mu_Vec2(150, 150)) == SplitZone.centre);
    assert(split_zone(r, 0, mu_Vec2(150,  50)) == SplitZone.up);
    assert(split_zone(r, 0, mu_Vec2(150, 250)) == SplitZone.down);
    assert(split_zone(r, 0, mu_Vec2( 50, 150)) == SplitZone.left);
    assert(split_zone(r, 0, mu_Vec2(250, 150)) == SplitZone.right);

    // Top boundary.
    assert(split_zone(r, 0, mu_Vec2(150,  99)) == SplitZone.up);
    assert(split_zone(r, 0, mu_Vec2(150, 100)) == SplitZone.centre);

    // Corners: nearer edge; diagonal ties go to left/right.
    assert(split_zone(r, 0, mu_Vec2(10, 40)) == SplitZone.left);
    assert(split_zone(r, 0, mu_Vec2(40, 10)) == SplitZone.up);
    assert(split_zone(r, 0, mu_Vec2(290, 20)) == SplitZone.right);
    assert(split_zone(r, 0, mu_Vec2(280, 10)) == SplitZone.up);

    // Zones are measured below the strip.
    static immutable mu_Rect capped = mu_Rect(0, 0, 300, 320);
    assert(split_zone(capped, 20, mu_Vec2(150,  0)) == SplitZone.centre);
    assert(split_zone(capped, 20, mu_Vec2( 10, 10)) == SplitZone.centre);
    assert(split_zone(capped, 20, mu_Vec2(150, 25)) == SplitZone.up);
    assert(split_zone(capped, 20, mu_Vec2(150, 170)) == SplitZone.centre);

    // Window coordinates.
    static immutable mu_Rect away = mu_Rect(500, 400, 300, 300);
    assert(split_zone(away, 0, mu_Vec2(650, 550)) == SplitZone.centre);
    assert(split_zone(away, 0, mu_Vec2(550, 550)) == SplitZone.left);
    assert(split_zone(away, 0, mu_Vec2(650, 450)) == SplitZone.up);

    // Outside: centre.
    assert(split_zone(away, 0, mu_Vec2(0, 0))     == SplitZone.centre);
    assert(split_zone(away, 0, mu_Vec2(800, 550)) == SplitZone.centre);

    // Strip only: centre.
    static immutable mu_Rect flat = mu_Rect(0, 0, 300, 20);
    assert(split_zone(flat, 20, mu_Vec2(150, 10)) == SplitZone.centre);
}

/// Half of `r` a drop in `zone` lands in (whole `r` for centre), for the
/// preview.
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

    // Far half gets the odd pixel, like split_layout.
    static immutable mu_Rect odd = mu_Rect(0, 0, 101, 61);
    assert(split_zone_rect(odd, SplitZone.left)  == mu_Rect(0, 0, 50, 61));
    assert(split_zone_rect(odd, SplitZone.right) == mu_Rect(50, 0, 51, 61));
    assert(split_zone_rect(odd, SplitZone.up)    == mu_Rect(0, 0, 101, 30));
    assert(split_zone_rect(odd, SplitZone.down)  == mu_Rect(0, 30, 101, 31));
}

/// Distribute `avail` pixels (splitters excluded) over `weights` into `sizes`.
/// All-zero weights share evenly. The last pane takes the remainder so the
/// sizes sum to `avail`.
void split_layout(const(int)[] weights, int avail, int[] sizes)
{
    assert(sizes.length >= weights.length);
    if (weights.length == 0)
        return;

    long total;
    foreach (int w; weights)
        total += w;

    // No weights: share evenly, avoid division by zero.
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

    // Remainder goes to the last pane.
    static immutable int[3] three = [ 1000, 1000, 1000 ];
    split_layout(three, 800, got);
    assert(got[0 .. 3] == [ 266, 266, 268 ]);
    assert(got[0] + got[1] + got[2] == 800);

    static immutable int[1] one = [ 1000 ];
    split_layout(one, 640, got);
    assert(got[0] == 640);

    // Zero weights: even, remainder on last.
    static immutable int[3] zero = [ 0, 0, 0 ];
    split_layout(zero, 100, got);
    assert(got[0 .. 3] == [ 33, 33, 34 ]);

    // No overflow on large windows.
    static immutable int[2] big = [ 1000, 1000 ];
    split_layout(big, 32000, got);
    assert(got[0 .. 2] == [ 16000, 16000 ]);
}

/// Move the boundary between panes `at` and `at + 1` by `dx` pixels (positive:
/// toward the end), adjusting `weights`. `avail` as for split_layout.
///
/// Only those two weights change and their sum is kept. Neither pane goes under
/// `minPx`, so a pane can't be collapsed and lost.
/// Returns: Pixels actually moved after clamping.
int split_resize(int[] weights, size_t at, int dx, int avail, int minPx)
{
    if (at + 1 >= weights.length || dx == 0 || avail <= 0)
        return 0;

    long total;
    foreach (int w; weights)
        total += w;
    if (total <= 0)
        return 0;

    // Clamp in pixels.
    int before = cast(int)((cast(long) avail * weights[at])     / total);
    int after  = cast(int)((cast(long) avail * weights[at + 1]) / total);

    // Window too small for the panes: no room, not negative.
    int room = before - minPx;
    if (room < 0) room = 0;
    int give = after - minPx;
    if (give < 0) give = 0;
    if (dx < -room) dx = -room;
    if (dx > give)  dx = give;
    if (dx == 0)
        return 0;

    // Keep the pair's sum exact so repeated drags don't drift.
    int sum = weights[at] + weights[at + 1];
    weights[at] = cast(int)((cast(long)(before + dx) * total) / avail);
    if (weights[at] > sum) weights[at] = sum;
    if (weights[at] < 0)   weights[at] = 0;
    weights[at + 1] = sum - weights[at];
    return dx;
}

unittest
{
    // 800px, drag 100 right: 500/300.
    int[2] w = [ 1000, 1000 ];
    assert(split_resize(w, 0, 100, 800, 100) == 100);
    int[4] got;
    split_layout(w, 800, got);
    assert(got[0 .. 2] == [ 500, 300 ]);
    assert(w[0] + w[1] == 2000); // sum conserved

    assert(split_resize(w, 0, -100, 800, 100) == -100);
    split_layout(w, 800, got);
    assert(got[0 .. 2] == [ 400, 400 ]);

    // Clamped at minPx: only 300 of 500 moves.
    int[2] floored = [ 1000, 1000 ];
    assert(split_resize(floored, 0, 500, 800, 100) == 300);
    split_layout(floored, 800, got);
    assert(got[0 .. 2] == [ 700, 100 ]);

    // At the floor: no further.
    assert(split_resize(floored, 0, 50, 800, 100) == 0);
    split_layout(floored, 800, got);
    assert(got[0 .. 2] == [ 700, 100 ]);

    // Reverse still works.
    assert(split_resize(floored, 0, -200, 800, 100) == -200);
    split_layout(floored, 800, got);
    assert(got[0 .. 2] == [ 500, 300 ]);

    // Middle boundary leaves the other pane alone.
    int[3] mid = [ 1000, 1000, 1000 ];
    assert(split_resize(mid, 1, 60, 900, 100) == 60);
    split_layout(mid, 900, got);
    assert(got[0] == 300);
    assert(got[1] + got[2] == 600);

    // Invalid requests are no-ops.
    int[2] safe = [ 1000, 1000 ];
    assert(split_resize(safe, 1, 50, 800, 100) == 0);  // no pane to the right
    assert(split_resize(safe, 0, 0,  800, 100) == 0);  // dx 0
    assert(split_resize(safe, 0, 50, 0,   100) == 0);  // no space
    assert(safe == [ 1000, 1000 ]);

    // Already too narrow: refused.
    int[2] tight = [ 1000, 1000 ];
    assert(split_resize(tight, 0, 40, 100, 100) == 0);
}

/// The About dialog's easter egg: an Elite (1984) title screen, tumbling
/// wireframe ship and all.
///
/// Drawn with real SDL line calls rather than out of ddui geometry. ddui's only
/// shape is a filled rectangle, so a wireframe through it would cost a command
/// per pixel run out of the 4096 a frame gets (MU_COMMANDLIST_SIZE), shared with
/// the hex panel behind it. Instead the window reserves a rectangle and pushes a
/// draw command of our own type, which render.d recognises and hands back here
/// at exactly the right point in the z-order. ddui defines no custom command and
/// reserves no user range, but it does not have to: the type field is a plain
/// int and our replay loop is the only thing that reads it.
/// Authors: dd
module elite;

import core.time : MonoTime;
import std.math : sin, cos;
import bindbc.sdl;
import ddui;

/// ddui draw command carrying the ship's panel, one past ddui's own types.
/// Pushed by elite_frame, dispatched by render_commands, drawn by elite_draw.
enum int MU_COMMAND_SHIP = MU_COMMAND_MAX;

/// Window title, and the key ddui pools the container under.
private immutable string TITLE = "--- E L I T E ---";

/// The prompt the 1984 title screen asks under the ship.
private immutable string PROMPT = "Load New Commander (Y/N)?";

// Window size in pixels, and the height reserved for the ship inside it.
private enum int WIDTH  = 420;
private enum int HEIGHT = 360;
private enum int PANEL  = 300;

// Tumble in radians per second. Deliberately unequal, so the ship never returns
// to the same attitude twice in a sitting.
private enum float YAW_RATE   = 0.7f;
private enum float PITCH_RATE = 0.23f;

// Camera sits this far up +Z from the model's origin, looking back down it. The
// model's own radius is about 1.4, so nothing ever crosses the eye.
private enum float CAMERA = 3.6f;

// Ship colour, and the black the panel is cleared to.
private enum SDL_Color SHIP_COLOR  = SDL_Color(210, 225, 255, 255);
private enum mu_Color  PANEL_COLOR = mu_Color(0, 0, 0, 255);

/// A point in model space: x right, y up, z out through the nose.
private struct Vec3
{
    float x;
    float y;
    float z;
}

// The Cobra Mk III, 28 vertices and 38 edges, in the units the 1984 game holds
// it in: x right, y up, z out through the nose, the hull 256 across and running
// from the tail at z = -40 to the laser mount at z = 90.
//
// Transcribed from the ship blueprint published at
// https://elite.bbcelite.com/cassette/main/variable/ship_cobra_mk_3.html,
// which is a disassembly of the original. The numbers are the shape and nothing
// else; the projection below is ours, so nothing here is derived from anyone's
// source but the table.
private immutable Vec3[28] modelVerts = [
    Vec3(  32,   0,  76), // 0  nose, right
    Vec3( -32,   0,  76), // 1  nose, left
    Vec3(   0,  26,  24), // 2  canopy peak
    Vec3(-120,  -3,  -8), // 3  left wing
    Vec3( 120,  -3,  -8), // 4  right wing
    Vec3( -88,  16, -40), // 5  rear, upper left
    Vec3(  88,  16, -40), // 6  rear, upper right
    Vec3( 128,  -8, -40), // 7  right wingtip, rear
    Vec3(-128,  -8, -40), // 8  left wingtip, rear
    Vec3(   0,  26, -40), // 9  rear, spine
    Vec3( -32, -24, -40), // 10 rear, lower left
    Vec3(  32, -24, -40), // 11 rear, lower right
    Vec3( -36,   8, -40), // 12 |
    Vec3(  -8,  12, -40), // 13 |
    Vec3(   8,  12, -40), // 14 |
    Vec3(  36,   8, -40), // 15 | the two panels across the back
    Vec3(  36, -12, -40), // 16 |
    Vec3(   8, -16, -40), // 17 |
    Vec3(  -8, -16, -40), // 18 |
    Vec3( -36, -12, -40), // 19 |
    Vec3(   0,   0,  76), // 20 laser mount, base
    Vec3(   0,   0,  90), // 21 laser mount, tip
    Vec3( -80,  -6, -40), // 22 |
    Vec3( -80,   6, -40), // 23 | left exhaust
    Vec3( -88,   0, -40), // 24 |
    Vec3(  80,   6, -40), // 25 |
    Vec3(  88,   0, -40), // 26 | right exhaust
    Vec3(  80,  -6, -40), // 27 |
];

// Vertex pairs, one line each.
private immutable ubyte[2][38] modelEdges = [
    [ 0,  1], [ 0,  4], [ 1,  3], [ 3,  8], [ 4,  7], // nose and wings
    [ 6,  7], [ 6,  9], [ 5,  9], [ 5,  8],           // upper rear
    [ 2,  5], [ 2,  6], [ 3,  5], [ 4,  6],           // canopy to the wings
    [ 1,  2], [ 0,  2], [ 2,  9],                     // canopy ridge
    [ 8, 10], [10, 11], [ 7, 11], [ 1, 10], [ 0, 11], // underside
    [ 1,  5], [ 0,  6],                               // upper hull
    [20, 21],                                         // laser mount
    [12, 13], [18, 19], [14, 15], [16, 17],           // |
    [15, 16], [14, 17], [13, 18], [12, 19],           // | back panels
    [22, 24], [23, 24], [22, 23],                     // left exhaust
    [25, 26], [26, 27], [25, 27],                     // right exhaust
];

// Model units per unit of the table above, and the shift that puts the middle of
// the hull on the origin: the published table measures from a point two thirds
// of the way to the nose, which would tumble the ship about its tail.
private enum float MODEL_SCALE = 1.0f / 128;
private enum float MODEL_ZOFF  = 25.0f;

/// Set when the About dialog is asked for the egg, consumed by the next frame.
/// Deferred for the same reason about_frame defers: placing the window needs the
/// current window size, which only the frame call knows.
private __gshared bool wantOpen;

/// Whether the window was up on the last frame, for elite_animating.
private __gshared bool showing;

/// Current attitude, advanced off the wall clock so the tumble runs at the same
/// rate whatever the frame rate is.
private __gshared float yaw;
private __gshared float pitch;
private __gshared MonoTime lastTick;

/// Request the title screen. Safe to call from anywhere in a frame.
void elite_open()
{
    wantOpen = true;
    yaw = 0;
    pitch = 0;
    lastTick = MonoTime.init;
}

/// True while the ship is on screen and the main loop owes it frames. Everything
/// else in vddhx is event-driven, so this is the only thing that keeps the loop
/// off SDL_WaitEvent, and only for as long as the window is open.
bool elite_animating()
{
    return showing;
}

/// Draw the window if it is open. Call once per frame, after the main window is
/// ended, so it lands as its own root container on top.
/// Params:
///     ctx = ddui context.
///     width = Current window width in pixels.
///     height = Current window height in pixels.
void elite_frame(mu_Context* ctx, int width, int height)
{
    if (wantOpen)
    {
        wantOpen = false;
        mu_Container* cnt = mu_get_container(ctx, TITLE);
        cnt.rect = mu_Rect((width - WIDTH) / 2, (height - HEIGHT) / 2, WIDTH, HEIGHT);
        cnt.open = 1;
        mu_bring_to_front(ctx, cnt);
    }

    if (mu_begin_window_ex(ctx, TITLE, mu_Rect(0, 0, WIDTH, HEIGHT),
            MU_OPT_NORESIZE | MU_OPT_NOSCROLL | MU_OPT_CLOSED) == 0)
    {
        showing = false;
        return;
    }
    showing = true;

    // Advance the tumble.
    version (Screenshot)
    {
        // The capture driver builds frames as fast as it can and its shots are
        // meant to be diffed against a previous run, so the wall clock is no use
        // to it: a fixed slice poses the ship the same way every time.
        enum float dt = 1.0f / 60;
    }
    else
    {
        // A stall (dragging the window, a modal file dialog) would otherwise
        // arrive as one enormous step, so cap the slice.
        MonoTime now = MonoTime.currTime;
        float dt = 0;
        if (lastTick != MonoTime.init)
        {
            dt = (now - lastTick).total!"usecs" / 1_000_000.0f;
            if (dt > 0.25f)
                dt = 0.25f;
        }
        lastTick = now;
    }
    yaw   += dt * YAW_RATE;
    pitch += dt * PITCH_RATE;

    // Space, and the ship over it. The rectangle has to be taken from the layout
    // before the command goes in, so the two agree on where it landed.
    static immutable int[1] full = [ -1 ];
    mu_layout_row(ctx, 1, full.ptr, PANEL);
    mu_Rect r = mu_layout_next(ctx);
    mu_draw_rect(ctx, r, PANEL_COLOR);
    mu_Command* cmd = mu_push_command(ctx, MU_COMMAND_SHIP);
    cmd.rect.rect = r;

    // ddui has no centred mu_label, so take the cell and draw into it the way
    // mu_label does, with the alignment bit set.
    mu_layout_row(ctx, 1, full.ptr, 0);
    mu_draw_control_text(ctx, PROMPT, mu_layout_next(ctx), MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);

    mu_end_window(ctx);
}

/// Draw the ship into the rectangle its command reserved. Called from
/// render_commands, in z-order, with the frame's clip state already applied.
void elite_draw(SDL_Renderer* renderer, mu_Rect panel)
{
    // Rotate, then project. Yaw about Y first, pitch about X after, which is
    // what makes the tumble read as a ship rolling rather than a spinning plate.
    const float cy = cos(yaw),   sy = sin(yaw);
    const float cp = cos(pitch), sp = sin(pitch);

    // Perspective scale, off the panel's short side so the window can be any
    // shape. The wingtips are the far corners of the hull at 1.03 model units,
    // and the nearest the tumble brings one to the eye is CAMERA - 1.03, so the
    // widest the ship can ever project is 0.4 of the focal length either side of
    // centre. At this factor that stays inside the panel at every attitude.
    const float focal = (panel.w < panel.h ? panel.w : panel.h) * 1.5f;
    const float ox = panel.x + panel.w / 2.0f;
    const float oy = panel.y + panel.h / 2.0f;

    SDL_FPoint[modelVerts.length] pts = void;
    foreach (size_t i, Vec3 v; modelVerts)
    {
        // Table units to model units, about the middle of the hull.
        float mx = v.x * MODEL_SCALE;
        float my = v.y * MODEL_SCALE;
        float mz = (v.z - MODEL_ZOFF) * MODEL_SCALE;

        float x = mx * cy + mz * sy;
        float z = mz * cy - mx * sy;
        float y = my * cp - z * sp;
        z = z * cp + my * sp;

        // Depth from the eye. Clamped rather than near-plane clipped: the model
        // never reaches the camera, so this only guards against a future one.
        float d = CAMERA - z;
        if (d < 0.1f)
            d = 0.1f;

        // Screen y grows downward, model y grows up.
        pts[i] = SDL_FPoint(ox + focal * x / d, oy - focal * y / d);
    }

    // Keep the ship inside its panel whatever the projection does, and hand the
    // renderer back the clip it had: render_commands drives its own from ddui's
    // clip commands and does not expect anyone to move it.
    SDL_Rect saved = void;
    const bool wasClipped = SDL_RenderClipEnabled(renderer);
    if (wasClipped)
        SDL_GetRenderClipRect(renderer, &saved);
    SDL_Rect clip = SDL_Rect(panel.x, panel.y, panel.w, panel.h);
    SDL_SetRenderClipRect(renderer, &clip);

    SDL_SetRenderDrawColor(renderer, SHIP_COLOR.r, SHIP_COLOR.g, SHIP_COLOR.b, SHIP_COLOR.a);
    foreach (ubyte[2] e; modelEdges)
        SDL_RenderLine(renderer, pts[e[0]].x, pts[e[0]].y, pts[e[1]].x, pts[e[1]].y);

    SDL_SetRenderClipRect(renderer, wasClipped ? &saved : null);
}

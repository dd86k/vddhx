/// About dialog easter egg: Elite (1984) title screen with a tumbling wireframe.
///
/// Drawn with SDL line calls, since ddui only has filled rects and a wireframe
/// would blow the 4096-command budget (MU_COMMANDLIST_SIZE). We push a custom
/// command type that render.d dispatches back here in z-order. ddui reserves no
/// user range, but the type is a plain int and only our replay loop reads it.
/// Authors: dd86k <dd@dax.moe>
module elite;

import core.time : MonoTime;
import std.math : sin, cos;
import bindbc.sdl;
import ddui;

/// Custom ddui command for the ship panel. Pushed by elite_frame, dispatched by
/// render_commands, drawn by elite_draw.
enum int MU_COMMAND_SHIP = MU_COMMAND_MAX;

/// Window title, also the container key.
private immutable string TITLE = "--- E L I T E ---";

/// The prompt the 1984 title screen asks under the ship.
private immutable string PROMPT = "Load New Commander (Y/N)?";

// Window size; PANEL is the ship's height.
private enum int WIDTH  = 420;
private enum int HEIGHT = 360;
private enum int PANEL  = 300;

// rad/s. Unequal so the attitude never repeats.
private enum float YAW_RATE   = 0.7f;
private enum float PITCH_RATE = 0.23f;

// Camera on +Z looking at the origin. Model radius is ~1.4.
private enum float CAMERA = 3.6f;

private enum SDL_Color SHIP_COLOR  = SDL_Color(210, 225, 255, 255);
private enum mu_Color  PANEL_COLOR = mu_Color(0, 0, 0, 255);

/// Model space: x right, y up, z forward.
private struct Vec3
{
    float x;
    float y;
    float z;
}

// Cobra Mk III in original game units (hull 256 wide, z from -40 to 90), from
// https://elite.bbcelite.com/cassette/main/variable/ship_cobra_mk_3.html
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

// Vertex pairs, one line each for the ship.
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

// Scale, and z offset to center the hull (the original origin is 2/3 toward
// the nose, which would tumble about the tail).
private enum float MODEL_SCALE = 1.0f / 128;
private enum float MODEL_ZOFF  = 25.0f;

// Deferred to the next frame (like about.d): placement needs the window size.
private __gshared bool wantOpen;

private __gshared bool showing;

// Advanced by wall clock so the rate is frame-rate independent.
private __gshared float yaw;
private __gshared float pitch;
private __gshared MonoTime lastTick;

/// Request the title screen. Safe anywhere in a frame.
void elite_open()
{
    wantOpen = true;
    yaw = 0;
    pitch = 0;
    lastTick = MonoTime.init;
}

/// True while open. Keeps the main loop off SDL_WaitEvent.
bool elite_animating()
{
    return showing;
}

/// Draw the window if open. Call once per frame after the main window ends, so
/// it's a root container on top.
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

    version (Screenshots)
    {
        // Fixed step so screenshots are reproducible.
        enum float dt = 1.0f / 60;
    }
    else
    {
        // Cap the step so stalls (window drag, modal dialog) don't jump.
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

    // Take the rect from the layout before pushing the command.
    static immutable int[1] full = [ -1 ];
    mu_layout_row(ctx, 1, full.ptr, PANEL);
    mu_Rect r = mu_layout_next(ctx);
    mu_draw_rect(ctx, r, PANEL_COLOR);
    mu_Command* cmd = mu_push_command(ctx, MU_COMMAND_SHIP);
    cmd.rect.rect = r;
    // ddui only hashes its own commands; force a redraw.
    mu_invalidate(ctx);

    // No centred mu_label; draw with the alignment flag.
    mu_layout_row(ctx, 1, full.ptr, 0);
    mu_draw_control_text(ctx, PROMPT, mu_layout_next(ctx), MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);

    mu_end_window(ctx);
}

/// Draw the ship in its reserved rect. Called from render_commands with clip
/// already applied.
void elite_draw(SDL_Renderer* renderer, mu_Rect panel)
{
    // Yaw about Y, then pitch about X.
    const float cy = cos(yaw),   sy = sin(yaw);
    const float cp = cos(pitch), sp = sin(pitch);

    // Focal length from the panel's short side. Wingtips reach 1.03 units, so the
    // projection stays within 0.4 focal lengths of center: inside the panel.
    const float focal = (panel.w < panel.h ? panel.w : panel.h) * 1.5f;
    const float ox = panel.x + panel.w / 2.0f;
    const float oy = panel.y + panel.h / 2.0f;

    SDL_FPoint[modelVerts.length] pts = void;
    foreach (size_t i, Vec3 v; modelVerts)
    {
        float mx = v.x * MODEL_SCALE;
        float my = v.y * MODEL_SCALE;
        float mz = (v.z - MODEL_ZOFF) * MODEL_SCALE;

        float x = mx * cy + mz * sy;
        float z = mz * cy - mx * sy;
        float y = my * cp - z * sp;
        z = z * cp + my * sp;

        // Clamp instead of near-plane clipping; the model never reaches the camera.
        float d = CAMERA - z;
        if (d < 0.1f)
            d = 0.1f;

        // Screen y is down.
        pts[i] = SDL_FPoint(ox + focal * x / d, oy - focal * y / d);
    }

    // Restore the clip after; render_commands manages it from ddui commands.
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

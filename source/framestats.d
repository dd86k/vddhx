/// Per-second frame timings, to judge whether skipping unchanged frames pays.
///
/// Build and hash average over every frame built, render and present over the
/// ones mu_frame_dirty let through.
module framestats;

version (FrameStats):

import core.time : MonoTime, Duration, seconds;
import ddlogger;
import ddui;

enum Phase { build, hash, render, present }

private __gshared
{
    MonoTime windowStart;
    MonoTime phaseStart;
    Duration[Phase.max + 1] spent;
    Duration[Phase.max + 1] worst;
    size_t events, frames, skipped, commands;
}

void stats_event()
{
    ++events;
}

void stats_begin()
{
    phaseStart = MonoTime.currTime;
    if (windowStart == MonoTime.init)
        windowStart = phaseStart;
}

/// Closes the running phase and opens the next one.
void stats_end(Phase phase)
{
    MonoTime now = MonoTime.currTime;
    Duration d = now - phaseStart;
    spent[phase] += d;
    if (d > worst[phase])
        worst[phase] = d;
    phaseStart = now;
}

/// Closes the hash phase, timing mu_frame_dirty.
void stats_dirty(mu_Context* ctx, bool dirty)
{
    if (dirty == false)
        ++skipped;
    commands += ctx.command_list.idx;
    stats_end(Phase.hash);
}

/// Call once per frame built, skipped or not. Logs and resets once a second has
/// passed.
void stats_frame_done()
{
    ++frames;
    MonoTime now = MonoTime.currTime;
    if (now - windowStart < 1.seconds)
        return;

    static double us(Duration d) { return d.total!"hnsecs" / 10.0; }
    double n = frames;
    double p = frames > skipped ? frames - skipped : 1;
    logInfo("frames %u (skipped %u) events %u cmds/frame %.0f | avg/max us: "~
        "build %.0f/%.0f hash %.0f/%.0f render %.0f/%.0f present %.0f/%.0f",
        frames, skipped, events, commands / n,
        us(spent[Phase.build])   / n, us(worst[Phase.build]),
        us(spent[Phase.hash])    / n, us(worst[Phase.hash]),
        us(spent[Phase.render])  / p, us(worst[Phase.render]),
        us(spent[Phase.present]) / p, us(worst[Phase.present]));

    spent[] = Duration.zero;
    worst[] = Duration.zero;
    events = frames = skipped = commands = 0;
    windowStart = now;
}

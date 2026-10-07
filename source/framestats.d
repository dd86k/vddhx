/// Per-second frame timings, to judge whether skipping unchanged frames pays.
///
/// Observes only: every frame is still drawn and presented, the hash is taken to
/// count the ones mu_frame_dirty would have skipped.
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
    size_t events, frames, unchanged, commands;
    mu_Id lastHash;
    bool haveHash;
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

/// Times the hash and counts the frame as one a skip would have dropped.
void stats_hash(mu_Context* ctx)
{
    mu_Id h = mu_frame_hash(ctx);
    if (haveHash && h == lastHash)
        ++unchanged;
    lastHash = h;
    haveHash = true;
    commands += ctx.command_list.idx;
    stats_end(Phase.hash);
}

/// Logs and resets once a second has passed, and only if frames were built.
void stats_frame_done()
{
    ++frames;
    MonoTime now = MonoTime.currTime;
    if (now - windowStart < 1.seconds)
        return;

    static double us(Duration d) { return d.total!"hnsecs" / 10.0; }
    double n = frames;
    logInfo("frames %u (unchanged %u) events %u cmds/frame %.0f | avg/max us: "~
        "build %.0f/%.0f hash %.0f/%.0f render %.0f/%.0f present %.0f/%.0f",
        frames, unchanged, events, commands / n,
        us(spent[Phase.build])   / n, us(worst[Phase.build]),
        us(spent[Phase.hash])    / n, us(worst[Phase.hash]),
        us(spent[Phase.render])  / n, us(worst[Phase.render]),
        us(spent[Phase.present]) / n, us(worst[Phase.present]));

    spent[] = Duration.zero;
    worst[] = Duration.zero;
    events = frames = unchanged = commands = 0;
    windowStart = now;
}

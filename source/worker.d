/// Background jobs modeled on .NET's BackgroundWorker: `doWork` runs on its own
/// thread; all other callbacks run on the UI thread via worker_pump.
///
/// Workers post to a locked queue and call `worker_wake`. Events are tagged
/// with a generation so a restarted run never receives stale events.
/// Authors: dd86k <dd@dax.moe>
module worker;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;

/// Called from the worker thread after each post to wake the UI loop.
/// Must be thread-safe.
__gshared void function() nothrow worker_wake;

final class BackgroundWorker
{
    /// Worker thread. Must not touch UI state until workDone.
    void delegate(BackgroundWorker) doWork;
    /// UI thread, from run(), before the thread starts.
    void delegate() runStarted;
    /// UI thread.
    void delegate(int percent) progressReported;
    /// UI thread, once per run unless abandoned. `error` is what doWork threw.
    void delegate(bool cancelled, Exception error) workDone;

    void run()
    {
        assert(busy == false, "worker already running");
        assert(doWork);
        atomicStore(cancelFlag, false);
        ++generation;
        lastPercent = -1;
        percent = 0;
        error = null;
        running = true;
        if (runStarted)
            runStarted();
        thread = new Thread(&threadMain);
        // Don't keep the process alive for a pending job on exit.
        thread.isDaemon = true;
        thread.start();
    }

    /// Request a stop; doWork must poll cancelled.
    void cancel()
    {
        atomicStore(cancelFlag, true);
    }

    /// Cancel, join, and drop the run; workDone never fires. For owners going away.
    void abandon()
    {
        if (running == false)
            return;
        cancel();
        thread.join(false);
        running = false;
        ++generation;
    }

    /// Any thread.
    bool cancelled()
    {
        return atomicLoad(cancelFlag);
    }

    /// For code polling a flag without the worker.
    shared(bool)* cancelToken()
    {
        return &cancelFlag;
    }

    /// UI thread: true between run() and workDone.
    bool busy() const
    {
        return running;
    }

    /// UI thread: last delivered percentage.
    int progress() const
    {
        return percent;
    }

    /// From doWork. Only changes are posted.
    void reportProgress(int value)
    {
        if (value == lastPercent)
            return;
        lastPercent = value;
        post(Event(this, generation, Kind.progress, value));
    }

    private:

    Thread thread;
    shared bool cancelFlag;
    uint generation;    // UI thread writes before thread start
    int lastPercent;    // worker thread only
    int percent;
    bool running;
    Exception error;    // worker writes, UI reads after join

    void threadMain()
    {
        try
            doWork(this);
        catch (Exception e)
            error = e;
        post(Event(this, generation, Kind.done, 0));
    }
}

/// Deliver events posted since the last call. UI thread, once per loop.
void worker_pump()
{
    Event[] batch;
    synchronized (queueLock)
    {
        if (queue.length == 0)
            return;
        batch = queue;
        queue = null;
    }

    foreach (ref Event e; batch)
    {
        BackgroundWorker w = e.worker;
        if (w.running == false || e.generation != w.generation)
            continue; // abandoned, maybe restarted
        final switch (e.kind)
        {
        case Kind.progress:
            w.percent = e.value;
            if (w.progressReported)
                w.progressReported(e.value);
            break;
        case Kind.done:
            w.thread.join(false);
            w.running = false;
            if (w.workDone)
                w.workDone(w.cancelled, w.error);
            break;
        }
    }
}

private:

enum Kind : ubyte { progress, done }

struct Event
{
    BackgroundWorker worker;
    uint generation;
    Kind kind;
    int value;
}

__gshared Mutex queueLock;
__gshared Event[] queue;

shared static this()
{
    queueLock = new Mutex();
}

void post(Event e)
{
    synchronized (queueLock)
        queue ~= e;
    if (worker_wake)
        worker_wake();
}

unittest
{
    import core.time : msecs;

    int[] seen;
    bool finished, wasCancelled;
    BackgroundWorker w = new BackgroundWorker;
    w.doWork = (BackgroundWorker self) {
        foreach (int i; 0 .. 5)
            self.reportProgress(i < 3 ? 50 : 100); // repeats coalesced
    };
    w.progressReported = (int p) { seen ~= p; };
    w.workDone = (bool c, Exception e) { finished = true; wasCancelled = c; };
    w.run();
    while (w.busy)
    {
        Thread.sleep(1.msecs);
        worker_pump();
    }
    assert(seen == [ 50, 100 ]);
    assert(finished && wasCancelled == false);

    // Abandon: thread is joined, its posts are dropped.
    finished = false;
    w.doWork = (BackgroundWorker self) {
        self.reportProgress(1);
        while (self.cancelled == false) {}
    };
    w.run();
    w.abandon();
    worker_pump();
    assert(finished == false && w.busy == false);

    // Exceptions go to workDone, not the thread's handler.
    Exception got;
    w.doWork = (BackgroundWorker self) { throw new Exception("boom"); };
    w.workDone = (bool c, Exception e) { got = e; };
    w.run();
    while (w.busy)
    {
        Thread.sleep(1.msecs);
        worker_pump();
    }
    assert(got && got.msg == "boom");
}

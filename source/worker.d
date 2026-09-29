/// Background jobs shaped like .NET's BackgroundWorker: `doWork` runs on a thread
/// of its own, and everything it reports reaches the UI thread through worker_pump,
/// so no other delegate ever runs anywhere else.
///
/// The worker thread only ever posts to a locked queue and calls `worker_wake`; the
/// UI thread drains it. A run's events carry its generation, so a worker abandoned
/// and started again within one pump cannot hand the new run the old run's news.
/// Authors: dd86k <dd@dax.moe>
module worker;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;

/// Called from the worker thread after every post, to rouse a UI loop sleeping on
/// its events. Must be safe to call from any thread.
__gshared void function() nothrow worker_wake;

final class BackgroundWorker
{
    /// Worker thread. Reads only what the UI thread leaves alone until workDone.
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
        // A job still walking a document when the window closes is not worth
        // holding the process open for.
        thread.isDaemon = true;
        thread.start();
    }

    /// Ask doWork to stop. It has to be looking: see cancelled.
    void cancel()
    {
        atomicStore(cancelFlag, true);
    }

    /// Cancel, wait the thread out, and forget the run: workDone never fires. For
    /// an owner that is going away and cannot take the answer.
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

    /// For code that polls a flag rather than holding the worker.
    shared(bool)* cancelToken()
    {
        return &cancelFlag;
    }

    /// UI thread: between run() and the workDone that ends it.
    bool busy() const
    {
        return running;
    }

    /// UI thread: the last percentage delivered.
    int progress() const
    {
        return percent;
    }

    /// From doWork. Only a change is posted, so a caller can report per window
    /// without flooding the queue.
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
    uint generation;    // UI thread writes, before the thread starts
    int lastPercent;    // worker thread only
    int percent;
    bool running;
    Exception error;    // worker thread writes, UI thread reads after join

    void threadMain()
    {
        try
            doWork(this);
        catch (Exception e)
            error = e;
        post(Event(this, generation, Kind.done, 0));
    }
}

/// Deliver whatever the workers have posted since the last call. UI thread, once
/// per loop iteration.
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
            continue; // abandoned, maybe already running again
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
            self.reportProgress(i < 3 ? 50 : 100); // repeats are coalesced
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

    // Abandoned: the thread is waited out and nothing it posted is delivered.
    finished = false;
    w.doWork = (BackgroundWorker self) {
        self.reportProgress(1);
        while (self.cancelled == false) {}
    };
    w.run();
    w.abandon();
    worker_pump();
    assert(finished == false && w.busy == false);

    // A throw reaches workDone rather than the thread's own handler.
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

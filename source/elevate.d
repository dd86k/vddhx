/// Opening what this process may not: an elevated copy of vddhx opens the target
/// and hands the handle back, so the editor itself never runs privileged.
///
/// The copy is started through pkexec on Posix and UAC on Windows, and does
/// nothing but open the one path. Posix passes the descriptor back over a socket
/// pair standing in for its stdin and stdout, the only descriptors pkexec leaves
/// open; Windows duplicates the handle straight into this process and exits with
/// its value.
module elevate;

import core.atomic : atomicLoad, atomicStore, cas;
import core.thread : Thread;
import ddhx.document : INVALID_OSHANDLE, OSHANDLE;
import os.error : OSException;

/// What the elevated copy is started with; main hands what follows it to
/// elevate_helper before SDL is touched.
enum string ELEVATE_ARG = "--elevated-open";

struct Elevated
{
    string path;
    bool write;
    /// INVALID_OSHANDLE unless it worked; owned by whoever polls it.
    OSHANDLE handle = INVALID_OSHANDLE;
    /// Why it did not, for the status bar.
    string error;
}

/// Whether `e` is a refusal on permissions, the one failure elevation can fix.
bool elevate_denied(Exception e)
{
    OSException os = cast(OSException) e;
    if (os is null)
        return false;
    version (Windows)
    {
        import core.sys.windows.winerror : ERROR_ACCESS_DENIED, ERROR_PRIVILEGE_NOT_HELD;
        return os.oscode == ERROR_ACCESS_DENIED || os.oscode == ERROR_PRIVILEGE_NOT_HELD;
    }
    else
    {
        import core.stdc.errno : EACCES, EPERM;
        return os.oscode == EACCES || os.oscode == EPERM;
    }
}

/// Ask for `path` opened by an elevated copy, `write` adding write access. The OS
/// prompt can sit there as long as the user leaves it, so this runs on a thread of
/// its own and `wake` is called once elevate_poll has an answer.
/// Returns: false when another request is still out.
bool elevate_request(string path, bool write, void function() nothrow wake)
{
    if (cas(&running, false, true) == false)
        return false;
    pending = Elevated(path, write);
    Thread t = new Thread({
        try
            elevate_run(pending);
        catch (Exception e)
            pending.error = e.msg;
        atomicStore(finished, true);
        wake();
    });
    t.isDaemon = true;
    t.start();
    return true;
}

/// Take the answer to the last request, once there is one.
bool elevate_poll(out Elevated answer)
{
    if (atomicLoad(finished) == false)
        return false;
    answer = pending;
    atomicStore(finished, false);
    atomicStore(running, false);
    return true;
}

private __gshared Elevated pending;
private shared bool running, finished;

private string selfPath()
{
    import std.file : thisExePath;
    return thisExePath();
}

version (Posix)
{
    import core.sys.posix.sys.socket;
    import core.sys.posix.sys.uio : iovec;
    import core.sys.posix.unistd : close;

    /// The elevated side: open `args[0]` (`args[1]` being "r" or "rw") and send the
    /// descriptor down stdout, or the errno that stopped it.
    int elevate_helper(string[] args)
    {
        import core.stdc.errno : EINVAL, errno;
        import core.sys.posix.fcntl : open, O_RDONLY, O_RDWR, O_NOCTTY;
        import std.string : toStringz;

        if (args.length < 2)
            return send(EINVAL, -1);
        int flags = (args[1] == "rw" ? O_RDWR : O_RDONLY) | O_NOCTTY;
        int fd = open(args[0].toStringz, flags);
        return send(fd < 0 ? errno : 0, fd);
    }

    private int send(int status, int fd)
    {
        iovec iov = iovec(&status, status.sizeof);
        msghdr msg;
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;

        ubyte[CMSG_SPACE(int.sizeof)] control;
        if (fd >= 0)
        {
            msg.msg_control = control.ptr;
            msg.msg_controllen = control.length;
            cmsghdr* cmsg = CMSG_FIRSTHDR(&msg);
            cmsg.cmsg_level = SOL_SOCKET;
            cmsg.cmsg_type  = SCM_RIGHTS;
            cmsg.cmsg_len   = CMSG_LEN(int.sizeof);
            *cast(int*) CMSG_DATA(cmsg) = fd;
        }
        return sendmsg(1, &msg, 0) < 0 ? 1 : 0;
    }

    private void elevate_run(ref Elevated job)
    {
        import core.stdc.string : strerror;
        import std.process : Pid, spawnProcess, wait, Config;
        import std.stdio : File, stderr;
        import std.string : fromStringz;

        int[2] sv;
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0)
            throw new OSException("socketpair");
        scope(exit) close(sv[0]);

        Pid pid;
        {
            File chan;
            chan.fdopen(sv[1], "r+b"); // owns sv[1] now; this end is the child's
            pid = spawnProcess(["pkexec", selfPath(), ELEVATE_ARG, job.path, job.write ? "rw" : "r"],
                chan, chan, stderr, null, Config.none);
        }

        int status = -1;
        iovec iov = iovec(&status, status.sizeof);
        ubyte[CMSG_SPACE(int.sizeof)] control;
        msghdr msg;
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.ptr;
        msg.msg_controllen = control.length;
        // Comes back empty when pkexec gives up before the copy ever runs.
        ptrdiff_t got = recvmsg(sv[0], &msg, 0);
        int code = wait(pid);

        if (got == status.sizeof && status == 0)
        {
            cmsghdr* cmsg = CMSG_FIRSTHDR(&msg);
            if (cmsg && cmsg.cmsg_type == SCM_RIGHTS)
                job.handle = *cast(int*) CMSG_DATA(cmsg);
            else
                job.error = "no descriptor came back";
        }
        else if (got == status.sizeof)
            job.error = strerror(status).fromStringz.idup;
        else if (code == 126)
            job.error = "authorization dismissed";
        else if (code == 127)
            job.error = "not authorized, or no authentication agent";
        else
            job.error = "pkexec failed";
    }
}

version (Windows)
{
    import core.sys.windows.windows;

    /// Exit codes with this bit are a Win32 error rather than a handle, which
    /// never carries it.
    private enum uint FAILED = 0x8000_0000;

    /// The elevated side: open `args[0]` (`args[1]` being "r" or "rw") and
    /// duplicate the handle into process `args[2]`, exiting with its value.
    int elevate_helper(string[] args)
    {
        import std.conv : to;
        import std.utf : toUTF16z;

        if (args.length < 3)
            return FAILED | ERROR_INVALID_PARAMETER;
        DWORD access = GENERIC_READ | (args[1] == "rw" ? GENERIC_WRITE : 0);
        DWORD pid;
        try
            pid = args[2].to!DWORD;
        catch (Exception)
            return FAILED | ERROR_INVALID_PARAMETER;

        HANDLE parent = OpenProcess(PROCESS_DUP_HANDLE, FALSE, pid);
        if (parent is null)
            return FAILED | GetLastError();
        scope(exit) CloseHandle(parent);

        HANDLE h = CreateFileW(args[0].toUTF16z, access, FILE_SHARE_READ | FILE_SHARE_WRITE,
            null, OPEN_EXISTING, 0, null);
        if (h == INVALID_HANDLE_VALUE)
            return FAILED | GetLastError();

        HANDLE dup;
        if (DuplicateHandle(GetCurrentProcess(), h, parent, &dup, 0, FALSE,
                DUPLICATE_SAME_ACCESS | DUPLICATE_CLOSE_SOURCE) == FALSE)
            return FAILED | GetLastError();
        // Handles are 32-bit significant even in a 64-bit process, so the exit code
        // carries one whole.
        return cast(int) cast(size_t) dup;
    }

    private void elevate_run(ref Elevated job)
    {
        import std.format : format;
        import std.process : escapeWindowsArgument, thisProcessID;
        import std.utf : toUTF16z;

        string params = format("%s %s %s %d", ELEVATE_ARG, escapeWindowsArgument(job.path),
            job.write ? "rw" : "r", thisProcessID);

        SHELLEXECUTEINFOW sei;
        sei.cbSize = sei.sizeof;
        sei.fMask = SEE_MASK_NOCLOSEPROCESS;
        sei.lpVerb = "runas"w.ptr;
        sei.lpFile = selfPath().toUTF16z;
        sei.lpParameters = params.toUTF16z;
        sei.nShow = SW_HIDE;
        if (ShellExecuteExW(&sei) == FALSE)
        {
            if (GetLastError() == ERROR_CANCELLED)
                job.error = "elevation declined";
            else
                throw new OSException("ShellExecuteExW");
            return;
        }
        scope(exit) CloseHandle(sei.hProcess);

        WaitForSingleObject(sei.hProcess, INFINITE);
        DWORD code;
        if (GetExitCodeProcess(sei.hProcess, &code) == FALSE)
            throw new OSException("GetExitCodeProcess");
        if (code & FAILED)
            job.error = new OSException(null, code & ~FAILED).msg;
        else if (code == 0)
            job.error = "the elevated copy failed";
        else
            job.handle = cast(HANDLE) cast(size_t) code;
    }
}

const builtin = @import("builtin");

/// Having a central place for libc because some header files
/// overwrite each other
pub const libc = @cImport({
    if (builtin.target.os.tag == .windows) {
        @cInclude("windows.h");
        @cInclude("winbase.h");
        @cInclude("psapi.h");
        @cInclude("tlhelp32.h");
        @cInclude("tchar.h");
        @cInclude("processthreadsapi.h");
        @cInclude("winreg.h");
    }

    if (builtin.target.os.tag != .windows) {
        @cInclude("fcntl.h");
        @cInclude("unistd.h");
        @cInclude("stdio.h");
        @cInclude("stdlib.h");
        @cInclude("errno.h");
        @cInclude("signal.h");
        @cInclude("sys/stat.h");
        @cInclude("sys/ioctl.h");
    }
    if (builtin.target.os.tag == .linux) {
        @cInclude("sys/sysinfo.h");
        @cInclude("limits.h");
        @cInclude("syscall.h");
        @cInclude("sys/resource.h");
        @cInclude("sys/prctl.h");
        @cInclude("linux/prctl.h");
        @cInclude("error.h");
    }
    if (builtin.target.os.tag == .macos) {
        @cInclude("libproc.h");
        @cInclude("sys/proc.h");
        @cInclude("mach/mach_time.h");
        @cInclude("sys/sysctl.h");
    }
});

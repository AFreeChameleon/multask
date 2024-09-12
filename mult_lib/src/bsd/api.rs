#![cfg(target_family = "unix")]

#[repr(C)]
pub struct procstat {
    pub pid: i32,
    pub status: i32,
    pub cmd: *const u8,
}

extern "C" {
    pub fn __error() -> *const i32;
    pub fn procstat_open_sysctl() -> *const procstat;
    pub fn procstat_getprocs(
        ps: *const procstat,
        what: i32,
        arg: i32,
        count: *mut u32
    ) -> *const libc::kinfo_proc;
}

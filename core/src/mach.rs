//! Mach entry points that `libc` has deprecated in favour of an extra crate.

use libc::mach_port_t;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TimebaseInfo {
    pub numer: u32,
    pub denom: u32,
}

extern "C" {
    fn mach_host_self() -> mach_port_t;
    fn mach_timebase_info(info: *mut TimebaseInfo) -> libc::c_int;
    static mach_task_self_: mach_port_t;
}

pub fn host_port() -> mach_port_t {
    unsafe { mach_host_self() }
}

pub fn task_port() -> mach_port_t {
    unsafe { mach_task_self_ }
}

/// Nanoseconds per unit of `mach_absolute_time`, which is what the per-process
/// CPU counters are measured in.
pub fn nanos_per_tick() -> f64 {
    let mut info = TimebaseInfo { numer: 1, denom: 1 };
    unsafe { mach_timebase_info(&mut info) };
    if info.denom == 0 {
        return 1.0;
    }
    info.numer as f64 / info.denom as f64
}

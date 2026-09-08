//! Memory figures shaped to match Activity Monitor's Memory tab.

use crate::sys::{page_size, sysctl_scalar};
use std::mem;

#[derive(Default)]
pub struct Memory {
    pub total: u64,
    pub used: u64,
    pub app: u64,
    pub wired: u64,
    pub compressed: u64,
    pub cached: u64,
    pub free: u64,
    /// Proxy for Activity Monitor's pressure graph: wired + compressed over total.
    pub pressure: f64,
    /// 0 = normal, 1 = warning, 2 = critical (kern.memorystatus_vm_pressure_level).
    pub pressure_level: u32,
    pub swap_total: u64,
    pub swap_used: u64,
}

pub fn sample() -> Memory {
    let mut out = Memory {
        total: sysctl_scalar::<u64>("hw.memsize").unwrap_or(0),
        ..Default::default()
    };

    let page = page_size();
    unsafe {
        let mut stats = mem::MaybeUninit::<libc::vm_statistics64>::zeroed();
        let mut count = (mem::size_of::<libc::vm_statistics64>() / mem::size_of::<libc::integer_t>())
            as libc::mach_msg_type_number_t;
        let result = libc::host_statistics64(
            crate::mach::host_port(),
            libc::HOST_VM_INFO64,
            stats.as_mut_ptr() as *mut libc::integer_t,
            &mut count,
        );
        if result == libc::KERN_SUCCESS {
            let s = stats.assume_init();
            out.wired = s.wire_count as u64 * page;
            out.compressed = s.compressor_page_count as u64 * page;
            out.free = s.free_count as u64 * page;
            // App Memory: anonymous pages that are not purgeable.
            let internal = s.internal_page_count as u64;
            let purgeable = s.purgeable_count as u64;
            out.app = internal.saturating_sub(purgeable) * page;
            // Cached Files: file-backed pages plus anything purgeable.
            out.cached = (s.external_page_count as u64 + purgeable) * page;
            out.used = out.app + out.wired + out.compressed;
        }
    }

    if out.total > 0 {
        out.pressure = (out.wired + out.compressed) as f64 / out.total as f64;
    }
    out.pressure_level = match sysctl_scalar::<u32>("kern.memorystatus_vm_pressure_level") {
        Some(4) => 2,
        Some(2) => 1,
        _ => 0,
    };

    if let Some(swap) = sysctl_scalar::<libc::xsw_usage>("vm.swapusage") {
        out.swap_total = swap.xsu_total;
        out.swap_used = swap.xsu_used;
    }

    out
}

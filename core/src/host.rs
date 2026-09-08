//! Machine identity and other values that do not change while running.

use crate::sys::{sysctl_scalar, sysctl_string};

pub struct HostInfo {
    pub model: String,
    pub chip: String,
    pub os_version: String,
    pub os_build: String,
    pub hostname: String,
    pub performance_cores: u32,
    pub efficiency_cores: u32,
    pub logical_cores: u32,
    pub memory_bytes: u64,
}

pub fn info() -> HostInfo {
    let performance = sysctl_scalar::<u32>("hw.perflevel0.logicalcpu").unwrap_or(0);
    let efficiency = sysctl_scalar::<u32>("hw.perflevel1.logicalcpu").unwrap_or(0);

    HostInfo {
        model: sysctl_string("hw.model").unwrap_or_else(|| "Mac".into()),
        chip: sysctl_string("machdep.cpu.brand_string").unwrap_or_else(|| "Unknown".into()),
        os_version: sysctl_string("kern.osproductversion").unwrap_or_default(),
        os_build: sysctl_string("kern.osversion").unwrap_or_default(),
        hostname: sysctl_string("kern.hostname").unwrap_or_default(),
        performance_cores: performance,
        efficiency_cores: efficiency,
        logical_cores: sysctl_scalar::<u32>("hw.logicalcpu").unwrap_or(0),
        memory_bytes: sysctl_scalar::<u64>("hw.memsize").unwrap_or(0),
    }
}

pub fn uptime_seconds() -> u64 {
    let boot = match sysctl_scalar::<libc::timeval>("kern.boottime") {
        Some(boot) => boot,
        None => return 0,
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    now.saturating_sub(boot.tv_sec as u64)
}

pub fn load_average() -> [f64; 3] {
    let mut values = [0.0f64; 3];
    unsafe { libc::getloadavg(values.as_mut_ptr(), 3) };
    values
}

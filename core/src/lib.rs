//! C ABI for the Readout metrics core.
//!
//! Every entry point writes into caller-provided storage, so the Swift side
//! never has to free anything. The only owned object is the sampler handle,
//! which holds the previous counters needed to turn monotonic totals into
//! rates.

pub mod cpu;
pub mod disk;
pub mod host;
pub mod mach;
pub mod mem;
pub mod net;
pub mod procs;
pub mod sys;

use std::ffi::c_char;

pub const RO_ABI_VERSION: u32 = 2;

pub const RO_SORT_CPU: u32 = 0;
pub const RO_SORT_MEMORY: u32 = 1;
pub const RO_SORT_ENERGY: u32 = 2;
pub const MAX_CORES: usize = cpu::MAX_CORES;

#[repr(C)]
pub struct RoHostInfo {
    pub model: [c_char; 64],
    pub chip: [c_char; 128],
    pub os_version: [c_char; 32],
    pub os_build: [c_char; 32],
    pub hostname: [c_char; 128],
    pub performance_cores: u32,
    pub efficiency_cores: u32,
    pub logical_cores: u32,
    pub memory_bytes: u64,
}

#[repr(C)]
pub struct RoSnapshot {
    pub cpu_total: f64,
    pub cpu_user: f64,
    pub cpu_system: f64,
    pub core_count: u32,
    pub cores: [f64; MAX_CORES],
    pub load_average: [f64; 3],
    pub uptime_seconds: u64,
    pub process_count: u32,

    pub memory_total: u64,
    pub memory_used: u64,
    pub memory_app: u64,
    pub memory_wired: u64,
    pub memory_compressed: u64,
    pub memory_cached: u64,
    pub memory_free: u64,
    pub memory_pressure: f64,
    pub memory_pressure_level: u32,
    pub swap_total: u64,
    pub swap_used: u64,

    pub network_rx_bytes_per_sec: f64,
    pub network_tx_bytes_per_sec: f64,
    pub network_rx_total: u64,
    pub network_tx_total: u64,
}

#[repr(C)]
pub struct RoVolume {
    pub name: [c_char; 64],
    pub mount_point: [c_char; 256],
    pub total: u64,
    pub free_bytes: u64,
    pub is_root: u32,
}

#[repr(C)]
pub struct RoProcess {
    pub pid: i32,
    pub name: [c_char; 64],
    pub cpu: f64,
    pub memory: u64,
    pub energy_impact: f64,
}

pub struct RoSampler {
    cpu: cpu::CpuSampler,
    net: net::NetSampler,
    procs: procs::ProcSampler,
}

#[no_mangle]
pub extern "C" fn ro_abi_version() -> u32 {
    RO_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn ro_sampler_new() -> *mut RoSampler {
    Box::into_raw(Box::new(RoSampler {
        cpu: cpu::CpuSampler::default(),
        net: net::NetSampler::new(),
        procs: procs::ProcSampler::new(),
    }))
}

/// # Safety
/// `sampler` must come from `ro_sampler_new` and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn ro_sampler_free(sampler: *mut RoSampler) {
    if !sampler.is_null() {
        drop(Box::from_raw(sampler));
    }
}

/// # Safety
/// `out` must point to a writable `RoHostInfo`.
#[no_mangle]
pub unsafe extern "C" fn ro_host_info(out: *mut RoHostInfo) {
    let out = match out.as_mut() {
        Some(out) => out,
        None => return,
    };
    let info = host::info();
    sys::copy_str(&mut out.model, &info.model);
    sys::copy_str(&mut out.chip, &info.chip);
    sys::copy_str(&mut out.os_version, &info.os_version);
    sys::copy_str(&mut out.os_build, &info.os_build);
    sys::copy_str(&mut out.hostname, &info.hostname);
    out.performance_cores = info.performance_cores;
    out.efficiency_cores = info.efficiency_cores;
    out.logical_cores = info.logical_cores;
    out.memory_bytes = info.memory_bytes;
}

/// Takes one reading of everything cheap enough to poll on a timer.
///
/// # Safety
/// `sampler` must come from `ro_sampler_new`; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn ro_sample(sampler: *mut RoSampler, out: *mut RoSnapshot) {
    let (sampler, out) = match (sampler.as_mut(), out.as_mut()) {
        (Some(sampler), Some(out)) => (sampler, out),
        _ => return,
    };

    let load = sampler.cpu.sample();
    out.cpu_total = load.total;
    out.cpu_user = load.user;
    out.cpu_system = load.system;
    out.core_count = load.cores.len().min(MAX_CORES) as u32;
    for (slot, value) in out.cores.iter_mut().zip(load.cores.iter()) {
        *slot = *value;
    }

    out.load_average = host::load_average();
    out.uptime_seconds = host::uptime_seconds();
    out.process_count = procs::count();

    let memory = mem::sample();
    out.memory_total = memory.total;
    out.memory_used = memory.used;
    out.memory_app = memory.app;
    out.memory_wired = memory.wired;
    out.memory_compressed = memory.compressed;
    out.memory_cached = memory.cached;
    out.memory_free = memory.free;
    out.memory_pressure = memory.pressure;
    out.memory_pressure_level = memory.pressure_level;
    out.swap_total = memory.swap_total;
    out.swap_used = memory.swap_used;

    let network = sampler.net.sample();
    out.network_rx_bytes_per_sec = network.rx_bytes_per_sec;
    out.network_tx_bytes_per_sec = network.tx_bytes_per_sec;
    out.network_rx_total = network.rx_total;
    out.network_tx_total = network.tx_total;
}

/// Fills up to `capacity` volumes and returns how many were written.
///
/// # Safety
/// `out` must point to at least `capacity` writable `RoVolume` values.
#[no_mangle]
pub unsafe extern "C" fn ro_volumes(out: *mut RoVolume, capacity: u32) -> u32 {
    if out.is_null() || capacity == 0 {
        return 0;
    }
    let slots = std::slice::from_raw_parts_mut(out, capacity as usize);
    let volumes = disk::volumes();
    let count = volumes.len().min(slots.len());
    for (slot, volume) in slots.iter_mut().zip(volumes.iter()) {
        sys::copy_str(&mut slot.name, &volume.name);
        sys::copy_str(&mut slot.mount_point, &volume.mount_point);
        slot.total = volume.total;
        slot.free_bytes = volume.free;
        slot.is_root = u32::from(volume.is_root);
    }
    count as u32
}

/// Fills up to `capacity` processes, heaviest first by `sort`, and returns how
/// many were written.
///
/// This walks every process, so call it on a slower cadence than `ro_sample`.
///
/// # Safety
/// `sampler` must come from `ro_sampler_new`; `out` must point to at least
/// `capacity` writable `RoProcess` values.
#[no_mangle]
pub unsafe extern "C" fn ro_top_processes(
    sampler: *mut RoSampler,
    out: *mut RoProcess,
    capacity: u32,
    sort: u32,
) -> u32 {
    let sampler = match sampler.as_mut() {
        Some(sampler) => sampler,
        None => return 0,
    };
    if out.is_null() || capacity == 0 {
        return 0;
    }

    let mut processes = sampler.procs.sample_apps();
    match sort {
        RO_SORT_MEMORY => processes.sort_by(|a, b| b.memory.cmp(&a.memory)),
        RO_SORT_ENERGY => processes.sort_by(|a, b| {
            b.energy_impact
                .partial_cmp(&a.energy_impact)
                .unwrap_or(std::cmp::Ordering::Equal)
        }),
        _ => processes.sort_by(|a, b| {
            b.cpu.partial_cmp(&a.cpu).unwrap_or(std::cmp::Ordering::Equal)
        }),
    }

    let slots = std::slice::from_raw_parts_mut(out, capacity as usize);
    let count = processes.len().min(slots.len());
    for (slot, process) in slots.iter_mut().zip(processes.iter()) {
        slot.pid = process.pid;
        sys::copy_str(&mut slot.name, &process.name);
        slot.cpu = process.cpu;
        slot.memory = process.memory;
        slot.energy_impact = process.energy_impact;
    }
    count as u32
}

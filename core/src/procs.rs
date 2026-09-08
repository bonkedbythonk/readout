//! Per-process CPU and memory, with CPU derived from deltas between samples.

use crate::sys::read_c_array;
use std::collections::HashMap;
use std::mem;
use std::time::Instant;

pub struct Process {
    pub pid: i32,
    pub parent_pid: i32,
    pub name: String,
    /// Share of a single core, so 2.0 means two cores fully busy.
    pub cpu: f64,
    /// Physical footprint: what the process actually costs the machine,
    /// including its compressed pages. Resident size is not the same thing and
    /// is badly wrong for some processes — a virtual machine holding 4 GB
    /// reports 40 MB resident.
    pub memory: u64,
    /// Relative energy impact over the interval. See `ENERGY_*` below for what
    /// goes into it; this is a score, not watts.
    pub energy_impact: f64,
}

#[derive(Clone, Copy)]
struct Counters {
    cpu_ticks: u64,
    idle_wakeups: u64,
    /// When the process started. The kernel reuses pids, and under heavy
    /// process churn a recycled pid otherwise compares a brand new process's
    /// lifetime counters against its predecessor's — which produced an energy
    /// score fifteen times the next app's, out of nowhere. A pid whose start
    /// time changed is a different process and has no history to difference.
    started: u64,
}

/// Weights for the energy impact score.
///
/// The kernel's own `ri_billed_energy` counter looks like the right input but
/// is not: a process pinning two cores reports zero through it, while an idle
/// one reports more. It accounts for work billed between processes, not power
/// drawn.
///
/// So impact is modelled the way Activity Monitor's column is — CPU time,
/// plus a penalty for waking an idle core, which costs far more battery than
/// the CPU time it shows up as. The result is deliberately a relative score
/// with no unit; real watts come from the SMC, for the machine as a whole.
const ENERGY_CPU_WEIGHT: f64 = 100.0;
const ENERGY_WAKEUP_WEIGHT: f64 = 0.4;

pub struct ProcSampler {
    previous: HashMap<i32, Counters>,
    /// The app each process's work belongs to, resolved once per pid.
    responsible: HashMap<i32, i32>,
    /// A process's executable never moves, so its bundle is resolved once.
    /// `proc_pidpath` is the most expensive call in this file and running it
    /// for every process on every sample was most of the sampler's own CPU
    /// cost. `None` records "looked, belongs to no bundle".
    bundles: HashMap<i32, Option<(String, String)>>,
    last_sampled: Option<Instant>,
    nanos_per_tick: f64,
}

impl ProcSampler {
    pub fn new() -> Self {
        Self {
            previous: HashMap::new(),
            responsible: HashMap::new(),
            bundles: HashMap::new(),
            last_sampled: None,
            nanos_per_tick: crate::mach::nanos_per_tick(),
        }
    }

    pub fn sample(&mut self) -> Vec<Process> {
        let pids = all_pids();
        let now = Instant::now();
        let elapsed_nanos = self
            .last_sampled
            .map(|at| now.duration_since(at).as_secs_f64() * 1e9)
            .unwrap_or(0.0);

        let mut current = HashMap::with_capacity(pids.len());
        let mut out = Vec::with_capacity(pids.len());

        for pid in pids {
            let info = match task_all_info(pid) {
                Some(info) => info,
                None => continue,
            };
            let usage = resource_usage(pid);
            let counters = Counters {
                cpu_ticks: info.ptinfo.pti_total_user + info.ptinfo.pti_total_system,
                idle_wakeups: usage.map(|usage| usage.idle_wakeups).unwrap_or(0),
                started: info.pbsd.pbi_start_tvsec,
            };
            current.insert(pid, counters);

            let before = self
                .previous
                .get(&pid)
                .copied()
                .filter(|before| before.started == counters.started);
            let (cpu, energy_impact) = match (before, elapsed_nanos > 0.0) {
                (Some(before), true) => {
                    let cpu_delta = counters
                        .cpu_ticks
                        .saturating_sub(before.cpu_ticks) as f64
                        * self.nanos_per_tick;
                    let cpu_share = cpu_delta / elapsed_nanos;
                    let wakeups = counters.idle_wakeups.saturating_sub(before.idle_wakeups) as f64;
                    let wakeups_per_second = wakeups / (elapsed_nanos / 1e9);
                    (
                        cpu_share,
                        cpu_share * ENERGY_CPU_WEIGHT
                            + wakeups_per_second * ENERGY_WAKEUP_WEIGHT,
                    )
                }
                _ => (0.0, 0.0),
            };

            let mut name = read_c_array(&info.pbsd.pbi_name);
            if name.is_empty() {
                name = read_c_array(&info.pbsd.pbi_comm);
            }
            if name.is_empty() {
                name = format!("pid {pid}");
            }

            out.push(Process {
                pid,
                parent_pid: info.pbsd.pbi_ppid as i32,
                name,
                cpu,
                // Fall back to resident size only when the footprint is
                // unavailable, which happens for processes this user may not
                // inspect.
                memory: usage
                    .map(|usage| usage.footprint)
                    .filter(|&footprint| footprint > 0)
                    .unwrap_or(info.ptinfo.pti_resident_size),
                energy_impact,
            });
        }

        // Drop cache entries for processes that have exited, so the map tracks
        // the live process table rather than growing for the whole session.
        self.bundles.retain(|pid, _| current.contains_key(pid));
        self.responsible.retain(|pid, _| current.contains_key(pid));

        self.previous = current;
        self.last_sampled = Some(now);
        out
    }

    /// Processes rolled up into the apps they belong to.
    ///
    /// A browser or an Electron app spreads its work over a main process and a
    /// swarm of renderers and GPU helpers. Listed separately they crowd out
    /// everything else and none of the rows answers "what is using my Mac".
    ///
    /// Each process is first attributed to the app *responsible* for it, which
    /// is how the system itself tracks this and how Activity Monitor groups
    /// its rows. That matters for work an app farms out to a system process:
    /// the virtual machine holding 4 GB on this Mac runs from
    /// `Virtualization.framework`, and only the responsibility link shows it
    /// is Claude's.
    ///
    /// Attribution then falls back to the bundle on disk: everything inside
    /// `Something.app` counts as Something, however deeply the helper bundles
    /// nest. Walking process *parents* instead would roll anything started
    /// from a terminal into the shell, which is not what a user means by an
    /// app. Processes belonging to no bundle group by executable name.
    pub fn sample_apps(&mut self) -> Vec<Process> {
        let processes = self.sample();

        let mut groups: HashMap<String, Process> = HashMap::new();
        let mut order: Vec<String> = Vec::new();

        for process in processes {
            let owner = *self
                .responsible
                .entry(process.pid)
                .or_insert_with(|| responsible_pid(process.pid));
            let bundle = match self.bundles.entry(owner).or_insert_with(|| app_bundle(owner)) {
                Some(bundle) => Some(bundle.clone()),
                // The responsible process may be gone or unreadable; fall back
                // to where this process's own executable lives.
                None if owner != process.pid => self
                    .bundles
                    .entry(process.pid)
                    .or_insert_with(|| app_bundle(process.pid))
                    .clone(),
                None => None,
            };

            let (key, name) = match bundle {
                Some((path, name)) => (path, name),
                None => (format!("exe:{}", process.name), process.name.clone()),
            };

            match groups.get_mut(&key) {
                Some(existing) => {
                    existing.cpu += process.cpu;
                    existing.memory += process.memory;
                    existing.energy_impact += process.energy_impact;
                }
                None => {
                    order.push(key.clone());
                    groups.insert(key, Process { parent_pid: 0, name, ..process });
                }
            }
        }

        order.into_iter().filter_map(|key| groups.remove(&key)).collect()
    }
}

fn all_pids() -> Vec<i32> {
    unsafe {
        // Both forms of this call return a *count of pids*, never a byte
        // count. Dividing the second result by the size of a pid — which the
        // name and much example code invite — silently keeps only a quarter of
        // the process table, and the processes it drops are exactly the ones
        // worth seeing: a 4 GB virtual machine sat outside the first quarter.
        // Verified against `ps`: 805 returned, 804 entries written, 806 live.
        let count = libc::proc_listallpids(std::ptr::null_mut(), 0);
        if count <= 0 {
            return Vec::new();
        }
        // Extra headroom: processes can appear between the two calls.
        let capacity = count as usize + 128;
        let mut pids = vec![0i32; capacity];
        let written = libc::proc_listallpids(
            pids.as_mut_ptr() as *mut libc::c_void,
            (capacity * mem::size_of::<i32>()) as libc::c_int,
        );
        if written <= 0 {
            return Vec::new();
        }
        pids.truncate(written as usize);
        pids.retain(|&pid| pid > 0);
        pids
    }
}

/// The process the system holds responsible for another process's work.
///
/// Resolved at run time because it is not in a public header. When it is
/// unavailable a process simply answers for itself, which is what it did
/// before this existed.
fn responsible_pid(pid: i32) -> i32 {
    use std::sync::OnceLock;
    type Responsible = unsafe extern "C" fn(libc::c_int) -> libc::c_int;
    static SYMBOL: OnceLock<Option<Responsible>> = OnceLock::new();

    let resolved = SYMBOL.get_or_init(|| unsafe {
        let name = c"responsibility_get_pid_responsible_for_pid";
        let address = libc::dlsym(libc::RTLD_DEFAULT, name.as_ptr());
        if address.is_null() {
            None
        } else {
            Some(std::mem::transmute::<*mut libc::c_void, Responsible>(address))
        }
    });

    match resolved {
        Some(function) => {
            let owner = unsafe { function(pid) };
            if owner > 0 { owner } else { pid }
        }
        None => pid,
    }
}

/// The outermost bundle a process's executable lives in, as (path, name).
///
/// Outermost matters: a helper's own path contains several bundle components,
/// and only the first names the thing the user recognises. `Discord Helper
/// (Renderer).app` nested inside `Discord.app` is Discord.
///
/// Frameworks and XPC services count too, not just apps. The XPC service that
/// runs a virtual machine is the largest single consumer of memory on this Mac
/// and its process name truncates to `com.apple.Virtualization.Virtua`;
/// attributed to the framework enclosing it, it reads as Virtualization.
fn app_bundle(pid: i32) -> Option<(String, String)> {
    let mut buffer = [0u8; 4096];
    let written = unsafe {
        libc::proc_pidpath(
            pid,
            buffer.as_mut_ptr() as *mut libc::c_void,
            buffer.len() as u32,
        )
    };
    if written <= 0 {
        return None;
    }
    let path = std::str::from_utf8(&buffer[..written as usize]).ok()?;

    // Whichever bundle type appears first is the outermost one.
    let (end, suffix) = [".app/", ".framework/", ".xpc/"]
        .iter()
        .filter_map(|marker| path.find(marker).map(|at| (at + marker.len() - 1, *marker)))
        .min_by_key(|(at, _)| *at)?;

    let bundle = &path[..end];
    let name = bundle
        .rsplit('/')
        .next()?
        .strip_suffix(suffix.trim_end_matches('/'))?
        .to_string();
    if name.is_empty() {
        return None;
    }
    Some((bundle.to_string(), name))
}

#[derive(Clone, Copy)]
struct ResourceUsage {
    /// Times the process has woken a core that had gone idle, since it started.
    idle_wakeups: u64,
    /// Physical footprint in bytes, compressed pages included.
    footprint: u64,
}

/// One rusage call serves both figures. Returns `None` for processes this user
/// is not allowed to inspect.
fn resource_usage(pid: i32) -> Option<ResourceUsage> {
    let mut info = mem::MaybeUninit::<libc::rusage_info_v4>::zeroed();
    let result = unsafe {
        libc::proc_pid_rusage(
            pid,
            libc::RUSAGE_INFO_V4,
            info.as_mut_ptr() as *mut libc::rusage_info_t,
        )
    };
    if result != 0 {
        return None;
    }
    let info = unsafe { info.assume_init() };
    Some(ResourceUsage {
        idle_wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
        footprint: info.ri_phys_footprint,
    })
}

fn task_all_info(pid: i32) -> Option<libc::proc_taskallinfo> {
    let mut info = mem::MaybeUninit::<libc::proc_taskallinfo>::zeroed();
    let size = mem::size_of::<libc::proc_taskallinfo>() as libc::c_int;
    let read = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTASKALLINFO,
            0,
            info.as_mut_ptr() as *mut libc::c_void,
            size,
        )
    };
    if read != size {
        return None;
    }
    Some(unsafe { info.assume_init() })
}

/// Cheap process count: a null buffer makes the kernel report the count only.
pub fn count() -> u32 {
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    count.max(0) as u32
}

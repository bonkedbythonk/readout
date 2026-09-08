//! Per-core and aggregate CPU load, sampled as deltas between calls.

use std::ffi::c_void;
use std::mem;

pub const MAX_CORES: usize = 64;

#[derive(Clone, Copy, Default)]
struct Ticks {
    user: u64,
    system: u64,
    idle: u64,
    nice: u64,
}

impl Ticks {
    fn busy(&self) -> u64 {
        self.user + self.system + self.nice
    }
    fn total(&self) -> u64 {
        self.busy() + self.idle
    }
}

#[derive(Default)]
pub struct CpuSampler {
    previous: Vec<Ticks>,
}

#[derive(Default)]
pub struct CpuLoad {
    pub total: f64,
    pub user: f64,
    pub system: f64,
    pub cores: Vec<f64>,
}

fn read_ticks() -> Option<Vec<Ticks>> {
    unsafe {
        let mut cpu_count: libc::natural_t = 0;
        let mut info: libc::processor_info_array_t = std::ptr::null_mut();
        let mut info_count: libc::mach_msg_type_number_t = 0;

        let result = libc::host_processor_info(
            crate::mach::host_port(),
            libc::PROCESSOR_CPU_LOAD_INFO,
            &mut cpu_count,
            &mut info,
            &mut info_count,
        );
        if result != libc::KERN_SUCCESS || info.is_null() {
            return None;
        }

        let loads = info as *const libc::processor_cpu_load_info;
        let mut out = Vec::with_capacity(cpu_count as usize);
        for i in 0..cpu_count as usize {
            let ticks = (*loads.add(i)).cpu_ticks;
            out.push(Ticks {
                user: ticks[libc::CPU_STATE_USER as usize] as u64,
                system: ticks[libc::CPU_STATE_SYSTEM as usize] as u64,
                idle: ticks[libc::CPU_STATE_IDLE as usize] as u64,
                nice: ticks[libc::CPU_STATE_NICE as usize] as u64,
            });
        }

        libc::vm_deallocate(
            crate::mach::task_port(),
            info as libc::vm_address_t,
            info_count as usize * mem::size_of::<libc::integer_t>(),
        );
        let _ = std::ptr::null::<c_void>();
        Some(out)
    }
}

impl CpuSampler {
    pub fn sample(&mut self) -> CpuLoad {
        let current = match read_ticks() {
            Some(ticks) => ticks,
            None => return CpuLoad::default(),
        };

        let mut load = CpuLoad {
            cores: Vec::with_capacity(current.len()),
            ..Default::default()
        };

        let have_previous = self.previous.len() == current.len();
        let (mut busy_sum, mut total_sum) = (0u64, 0u64);
        let (mut user_sum, mut system_sum) = (0u64, 0u64);

        for (index, now) in current.iter().enumerate() {
            let before = if have_previous {
                self.previous[index]
            } else {
                Ticks::default()
            };
            // Tick counters are monotonic, but guard against counter resets.
            let busy = now.busy().saturating_sub(before.busy());
            let total = now.total().saturating_sub(before.total());
            busy_sum += busy;
            total_sum += total;
            user_sum += (now.user + now.nice).saturating_sub(before.user + before.nice);
            system_sum += now.system.saturating_sub(before.system);
            load.cores.push(if total > 0 {
                busy as f64 / total as f64
            } else {
                0.0
            });
        }

        if total_sum > 0 {
            load.total = busy_sum as f64 / total_sum as f64;
            load.user = user_sum as f64 / total_sum as f64;
            load.system = system_sum as f64 / total_sum as f64;
        }

        self.previous = current;
        load
    }
}

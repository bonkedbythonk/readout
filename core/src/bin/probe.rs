//! Times each part of a sample so the app's own cost can be attributed.

use std::time::{Duration, Instant};
use readout_core::{cpu, disk, host, mem, net, procs};

fn time<T>(label: &str, iterations: u32, mut work: impl FnMut() -> T) {
    let start = Instant::now();
    for _ in 0..iterations {
        std::hint::black_box(work());
    }
    let each = start.elapsed().as_secs_f64() * 1000.0 / iterations as f64;
    println!("  {label:<22} {each:>8.3} ms");
}

fn main() {
    let mut cpu_sampler = cpu::CpuSampler::default();
    let mut net_sampler = net::NetSampler::new();
    let mut proc_sampler = procs::ProcSampler::new();
    let _ = proc_sampler.sample_apps();
    std::thread::sleep(Duration::from_millis(200));

    println!("per call:");
    time("cpu", 20, || cpu_sampler.sample());
    time("memory", 20, || mem::sample());
    time("network", 20, || net_sampler.sample());
    time("volumes", 20, || disk::volumes());
    time("host info", 20, || host::info());
    time("processes (warm)", 5, || proc_sampler.sample_apps());

    let mut cold = procs::ProcSampler::new();
    time("processes (cold)", 1, || cold.sample_apps());

    // Energy impact broken into its parts, to check an outlier is real.
    std::thread::sleep(Duration::from_millis(1000));
    let mut parts = proc_sampler.sample_apps();
    parts.sort_by(|a, b| b.energy_impact.partial_cmp(&a.energy_impact).unwrap());
    println!("\nenergy impact = cpu*100 + wakeups/s*0.4:");
    for app in parts.iter().take(6) {
        let from_cpu = app.cpu * 100.0;
        println!("  {:<24} impact {:>7.0}  cpu {:>6.1}%  implied wakeups/s {:>8.0}",
            app.name, app.energy_impact, app.cpu * 100.0,
            (app.energy_impact - from_cpu) / 0.4);
    }

    let mut apps = proc_sampler.sample_apps();
    apps.sort_by_key(|app| std::cmp::Reverse(app.memory));
    println!("\ntop by memory (physical footprint):");
    for app in apps.iter().take(10) {
        println!("  {:<34} {:>8.2} GB", app.name, app.memory as f64 / 1_073_741_824.0);
    }
}

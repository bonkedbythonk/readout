# Readout

A macOS menu bar system monitor. Rust reads the machine, Swift draws it.

The menu bar carries only the app's mark. Readings live in the panel that drops
out of it; anything you would go looking for deliberately — battery cycles,
per-core load, every mounted volume — lives in a separate details window.

## Layout

```
core/                  Rust metrics core, built as a static library
  src/cpu.rs           per-core load from host_processor_info deltas
  src/mem.rs           Activity Monitor's memory figures from host_statistics64
  src/net.rs           throughput from the routing table's 64-bit counters
  src/disk.rs          mounted volumes via getfsstat
  src/procs.rs         per-process CPU, memory and energy, grouped into apps
  src/host.rs          machine identity, uptime, load average
  src/lib.rs           the C ABI
  src/bin/probe.rs     times each subsystem (cargo run --bin probe)
Sources/CReadoutCore/   the header the Swift side imports
Sources/Readout/        the app
  Sensors/             IOKit: thermals, SMC, GPU, battery
  Model/               sampling actor, observable model, formatting
  Views/               panel, details window, cards
Scripts/               build, package, run
```

## Build and run

```bash
Scripts/compile_and_run.sh
```

That builds the Rust core, builds the app, assembles `Readout.app`, signs it
ad hoc and launches it. `Scripts/package_app.sh release` stops after packaging.

Apple silicon only as written: `Scripts/build_rust.sh` maps `arm64` to
`aarch64-apple-darwin` and refuses an arch whose Rust target is not installed.

## Where the numbers come from

| Reading | Source |
|---|---|
| CPU, per core | `host_processor_info`, tick deltas between samples |
| Memory | `host_statistics64`; used = app + wired + compressed, as Activity Monitor counts it |
| Memory pressure | `kern.memorystatus_vm_pressure_level` — the state macOS itself acts on |
| Network | `NET_RT_IFLIST2`, whose counters are 64-bit and so do not wrap |
| Volumes | `getfsstat`, filtered to the startup disk and `/Volumes` |
| Processes | `proc_listallpids` + `proc_pidinfo`, grouped by responsible app |
| Temperatures | `IOHIDEventSystemClient` on the Apple vendor HID page |
| Fans, system power | SMC keys `F*Ac`, `PSTR` |
| GPU | `IOAccelerator`'s `PerformanceStatistics` |
| Battery | `AppleSmartBattery` in the IO registry |

Units follow the system: memory in binary GB like Activity Monitor, storage and
network in decimal GB like Finder.

## Things worth knowing

**Processes are grouped by app, not by process.** An Electron app spreads its
work over a main process and a swarm of helpers; listed separately they crowd
out everything else. Each process is attributed to the app the system holds
*responsible* for it (`responsibility_get_pid_responsible_for_pid`, the same
link Activity Monitor groups by), falling back to the bundle its executable
lives in. Both steps earn their place: responsibility is the only thing that
connects a 4 GB virtual machine running out of `Virtualization.framework` to
the app that asked for it, and the bundle is what folds a swarm of renderer
helpers back into their app. Grouping by process *parent* was tried first and
was wrong — it rolls everything started from a terminal into `zsh`.

**Energy is a score, not watts.** The kernel's per-process energy counter
(`ri_billed_energy`) looks like the right input and is not — measured, a process
pinning two cores reports zero through it while an idle one reports more. It
accounts for work billed between processes, not power drawn. Energy impact is
therefore modelled the way Activity Monitor's column is: CPU time plus a penalty
for waking an idle core. Real watts come from the SMC, for the machine as a
whole.

**Process memory is the physical footprint, not resident size.** Resident size
is what `ps` reports and it is badly wrong for some processes: a virtual machine
holding 4 GB reports 40 MB resident and 0.2% memory. `ri_phys_footprint` from
`proc_pid_rusage` is what Activity Monitor's Memory column shows and what
actually counts against memory pressure, compressed pages included. It comes
from the same rusage call the energy score already makes, so it is free.

**`proc_listallpids` returns a pid count, in both of its forms.** Neither result
is a byte count, and dividing the second one by the size of a pid — which the
name invites, and which this code did — silently keeps a quarter of the process
table while looking entirely healthy. The processes it dropped were the ones
worth seeing. Verified against `ps`: 805 returned, 804 written, 806 live.

**Deltas are guarded against pid reuse.** Every rate here differences a
lifetime counter against the previous sample. The kernel reuses pids, so under
heavy process churn a recycled pid compares a brand new process's counters
against its predecessor's — which showed up once as an energy score fifteen
times the next app's, appearing from nowhere. Each sample also records the
process start time, and a pid whose start time changed is treated as a new
process with no history.

**Only your own processes are visible.** `proc_pidinfo` returns nothing for
other users' processes without privileges. `/usr/bin/top` sees them because it
is setuid root; Readout does not ask for that. In practice the apps you care
about run as you.

**Memory pressure sitting at "Warning" is usually real.** The word comes
straight from `kern.memorystatus_vm_pressure_level`, the state macOS itself acts
on. macOS deliberately keeps memory spoken for rather than idle, so a well-used
Mac lives at Warning for long stretches. Only Critical is coloured.

**Sensor reads are wildly uneven in cost.** The thermal sensors cost more than
everything else in a sample put together: 80 ms, against under 0.05 ms for the
entire Rust core. They are deduplicated by name and read on a slower beat than
the rest. `READOUT_BENCH=1 ./Readout.app/Contents/MacOS/Readout` re-measures this;
anything added later should be measured rather than assumed cheap.

**Never write observed state during layout.** The panel measures its content
with a `GeometryReader` to size itself. Storing that height in the `@Observable`
model — read by the same view's `.frame` — re-invalidated the view every layout
pass and cost 11% CPU the whole time the panel was open. It lives in `@State`,
and is handed to the model only on close so the next opening starts at the right
size.

Measured on an M4 Pro with `top -pid`: 0% CPU with nothing open, around 5% while
the panel is open, and low double digits while the details window is open and
updating. Verify the window is actually open before trusting a reading — a
scripted click that misses makes an idle process look like a cheap one.

## Private API

Thermal sensors go through `IOHIDEventSystemClient`, which is not in any public
header, and the responsive-scrolling fix patches a private SwiftUI class. Both
resolve their symbols at run time and degrade to doing nothing if a future macOS
drops them. Neither is App Store material.

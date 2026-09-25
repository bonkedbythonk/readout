//! Aggregate network throughput from the routing table's interface counters.
//!
//! The counters are 64-bit fields, but the kernel only fills them to 64 bits
//! for callers holding a private entitlement (`netstat` has it). Everyone else
//! gets them truncated to 32 bits and rounded to the kilobyte, so they wrap
//! every 4 GB. Each interface is therefore differenced on its own, allowing
//! for the wrap, and only then summed: a sum of wrapping counters wraps at no
//! fixed point and cannot be unpicked. For the same reason there is no honest
//! total since boot to report.

use crate::sys::sysctl_mib_bytes;
use std::collections::HashMap;
use std::mem;
use std::time::Instant;

#[derive(Default, Clone, Copy)]
struct Counters {
    rx: u64,
    tx: u64,
}

/// `IFT_LOOP` from `<net/if_types.h>`, which `libc` does not export.
const IFT_LOOP: u8 = 0x18;

/// Where a 32-bit counter wraps.
const WRAP: u64 = 1 << 32;

#[derive(Default)]
pub struct NetSampler {
    /// Each interface's counters, keyed by interface index.
    previous: Option<(HashMap<u16, Counters>, Instant)>,
}

#[derive(Default)]
pub struct NetLoad {
    pub rx_bytes_per_sec: f64,
    pub tx_bytes_per_sec: f64,
}

impl NetSampler {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn sample(&mut self) -> NetLoad {
        let current = read_counters();
        let now = Instant::now();
        let mut load = NetLoad::default();

        if let Some((before, at)) = &self.previous {
            let elapsed = now.duration_since(*at).as_secs_f64();
            if elapsed > 0.01 {
                let (mut rx, mut tx) = (0u64, 0u64);
                for (index, now) in &current {
                    // An interface that appeared since the last reading has
                    // nothing to difference against yet.
                    if let Some(before) = before.get(index) {
                        rx += counter_delta(before.rx, now.rx);
                        tx += counter_delta(before.tx, now.tx);
                    }
                }
                load.rx_bytes_per_sec = rx as f64 / elapsed;
                load.tx_bytes_per_sec = tx as f64 / elapsed;
            }
        }

        self.previous = Some((current, now));
        load
    }
}

/// Bytes counted between two readings of one interface's counter.
fn counter_delta(before: u64, now: u64) -> u64 {
    if now >= before {
        return now - before;
    }
    // Going backwards is usually a 32-bit wrap. Readings are at most a couple
    // of seconds apart, so a genuine wrap moves well under half the range.
    if before < WRAP {
        let wrapped = now + WRAP - before;
        if wrapped < WRAP / 2 {
            return wrapped;
        }
    }
    // Otherwise the interface was torn down and recreated under the same
    // index, starting again from zero. Its bytes for this one interval are
    // lost rather than invented.
    0
}

fn read_counters() -> HashMap<u16, Counters> {
    let mut mib = [
        libc::CTL_NET,
        libc::AF_ROUTE,
        0,
        0,
        libc::NET_RT_IFLIST2,
        0,
    ];
    let mut counters = HashMap::new();
    let buf = match sysctl_mib_bytes(&mut mib) {
        Some(buf) => buf,
        None => return counters,
    };

    let mut offset = 0usize;
    let header_size = mem::size_of::<libc::if_msghdr2>();

    while offset + mem::size_of::<libc::if_msghdr>() <= buf.len() {
        let base = unsafe { buf.as_ptr().add(offset) };
        let msglen = unsafe { std::ptr::read_unaligned(base as *const u16) } as usize;
        if msglen == 0 || offset + msglen > buf.len() {
            break;
        }

        let msg_type = unsafe { std::ptr::read_unaligned(base.add(3)) };
        if msg_type as i32 == libc::RTM_IFINFO2 && msglen >= header_size {
            let header: libc::if_msghdr2 = unsafe { std::ptr::read_unaligned(base as *const _) };
            // The type is in the header itself. Reading the name out of the
            // sockaddr_dl that follows meant indexing libc's 12-byte
            // `sdl_data`, which panics — and so aborts the app — for any
            // interface name longer than that.
            if header.ifm_data.ifi_type != IFT_LOOP {
                counters.insert(
                    header.ifm_index,
                    Counters {
                        rx: header.ifm_data.ifi_ibytes,
                        tx: header.ifm_data.ifi_obytes,
                    },
                );
            }
        }

        offset += msglen;
    }

    counters
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_forward_movement() {
        assert_eq!(counter_delta(1_000, 5_096), 4_096);
        assert_eq!(counter_delta(7_000, 7_000), 0);
    }

    #[test]
    fn unwraps_a_32_bit_counter() {
        assert_eq!(counter_delta(WRAP - 1_024, 2_048), 3_072);
    }

    #[test]
    fn treats_a_reset_as_no_traffic() {
        // A recreated interface drops back from a modest count to near zero,
        // which read as a wrap would be almost 4 GB in one interval.
        assert_eq!(counter_delta(50_000_000, 1_024), 0);
    }

    #[test]
    fn full_width_counters_never_wrap() {
        // With the entitlement, counters are genuinely 64-bit; going
        // backwards past 4 GB can only be a reset.
        assert_eq!(counter_delta(WRAP * 30, 1_024), 0);
    }
}

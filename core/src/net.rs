//! Aggregate network throughput from the routing table's 64-bit counters.

use crate::sys::sysctl_mib_bytes;
use std::mem;
use std::time::Instant;

#[derive(Default, Clone, Copy)]
pub struct Counters {
    pub rx: u64,
    pub tx: u64,
}

pub struct NetSampler {
    previous: Option<(Counters, Instant)>,
}

#[derive(Default)]
pub struct NetLoad {
    pub rx_bytes_per_sec: f64,
    pub tx_bytes_per_sec: f64,
    pub rx_total: u64,
    pub tx_total: u64,
}

impl NetSampler {
    pub fn new() -> Self {
        Self { previous: None }
    }

    pub fn sample(&mut self) -> NetLoad {
        let current = read_counters();
        let now = Instant::now();
        let mut load = NetLoad {
            rx_total: current.rx,
            tx_total: current.tx,
            ..Default::default()
        };

        if let Some((before, at)) = self.previous {
            let elapsed = now.duration_since(at).as_secs_f64();
            if elapsed > 0.01 {
                load.rx_bytes_per_sec = current.rx.saturating_sub(before.rx) as f64 / elapsed;
                load.tx_bytes_per_sec = current.tx.saturating_sub(before.tx) as f64 / elapsed;
            }
        }

        self.previous = Some((current, now));
        load
    }
}

fn read_counters() -> Counters {
    let mut mib = [
        libc::CTL_NET,
        libc::AF_ROUTE,
        0,
        0,
        libc::NET_RT_IFLIST2,
        0,
    ];
    let buf = match sysctl_mib_bytes(&mut mib) {
        Some(buf) => buf,
        None => return Counters::default(),
    };

    let mut totals = Counters::default();
    let mut offset = 0usize;
    let header_size = mem::size_of::<libc::if_msghdr2>();

    while offset + mem::size_of::<libc::if_msghdr>() <= buf.len() {
        let base = unsafe { buf.as_ptr().add(offset) };
        let msglen = unsafe { std::ptr::read_unaligned(base as *const u16) } as usize;
        if msglen == 0 || offset + msglen > buf.len() {
            break;
        }

        let msg_type = unsafe { std::ptr::read_unaligned(base.add(3) as *const u8) };
        if msg_type as i32 == libc::RTM_IFINFO2 && msglen >= header_size {
            let header: libc::if_msghdr2 = unsafe { std::ptr::read_unaligned(base as *const _) };
            // The interface's sockaddr_dl follows the header and carries its name.
            let is_loopback = unsafe {
                let sdl = base.add(header_size) as *const libc::sockaddr_dl;
                let name_len = (*sdl).sdl_nlen as usize;
                let name: Vec<u8> = (0..name_len.min(16))
                    .map(|i| (*sdl).sdl_data[i] as u8)
                    .collect();
                name.starts_with(b"lo")
            };
            if !is_loopback {
                totals.rx += header.ifm_data.ifi_ibytes;
                totals.tx += header.ifm_data.ifi_obytes;
            }
        }

        offset += msglen;
    }

    totals
}

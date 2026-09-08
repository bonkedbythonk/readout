//! Mounted local volumes and their capacity.

use crate::sys::read_c_array;
use std::mem;

pub struct Volume {
    pub name: String,
    pub mount_point: String,
    pub total: u64,
    pub free: u64,
    pub is_root: bool,
}

pub fn volumes() -> Vec<Volume> {
    let count = unsafe { libc::getfsstat(std::ptr::null_mut(), 0, libc::MNT_NOWAIT) };
    if count <= 0 {
        return Vec::new();
    }

    let mut buf: Vec<libc::statfs> = Vec::with_capacity(count as usize);
    let bytes = count as usize * mem::size_of::<libc::statfs>();
    let written = unsafe { libc::getfsstat(buf.as_mut_ptr(), bytes as libc::c_int, libc::MNT_NOWAIT) };
    if written <= 0 {
        return Vec::new();
    }
    unsafe { buf.set_len(written as usize) };

    let mut out = Vec::new();
    for fs in buf.iter() {
        // Only physical, locally attached filesystems are interesting here.
        if fs.f_flags & libc::MNT_LOCAL as u32 == 0 {
            continue;
        }
        let fstype = read_c_array(&fs.f_fstypename);
        if !matches!(fstype.as_str(), "apfs" | "hfs" | "exfat" | "msdos" | "ntfs" | "udf") {
            continue;
        }

        let mount_point = read_c_array(&fs.f_mntonname);
        let is_root = mount_point == "/" || mount_point == "/System/Volumes/Data";
        // Finder's rule: the startup disk, plus anything mounted in /Volumes.
        // That leaves out cryptex mounts, simulator runtimes and the VM store,
        // none of which a user thinks of as a disk.
        if !is_root && !mount_point.starts_with("/Volumes/") {
            continue;
        }

        let block = fs.f_bsize as u64;
        let total = fs.f_blocks * block;
        if total == 0 {
            continue;
        }

        let name = if is_root {
            "Macintosh HD".to_string()
        } else {
            mount_point
                .rsplit('/')
                .next()
                .unwrap_or(&mount_point)
                .to_string()
        };

        out.push(Volume {
            name,
            mount_point,
            total,
            free: fs.f_bavail * block,
            is_root,
        });
    }

    // The root volume should always lead the list.
    out.sort_by_key(|v| (!v.is_root, v.name.clone()));
    out.dedup_by(|a, b| a.is_root && b.is_root);
    out
}

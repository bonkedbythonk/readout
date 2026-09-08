//! Small wrappers over sysctl and C string handling.

use std::ffi::{c_char, c_void, CString};
use std::ptr;

/// Copies `src` into a fixed-size C char array, truncating and NUL-terminating.
pub fn copy_str(dst: &mut [c_char], src: &str) {
    let bytes = src.as_bytes();
    let limit = dst.len().saturating_sub(1);
    let n = bytes.len().min(limit);
    for i in 0..n {
        dst[i] = bytes[i] as c_char;
    }
    for slot in dst.iter_mut().skip(n) {
        *slot = 0;
    }
}

/// Reads a NUL-terminated C string out of a fixed-size buffer.
pub fn read_c_array(src: &[c_char]) -> String {
    let bytes: Vec<u8> = src
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

pub fn sysctl_string(name: &str) -> Option<String> {
    let cname = CString::new(name).ok()?;
    let mut size: usize = 0;
    unsafe {
        if libc::sysctlbyname(cname.as_ptr(), ptr::null_mut(), &mut size, ptr::null_mut(), 0) != 0 {
            return None;
        }
        let mut buf = vec![0u8; size];
        if libc::sysctlbyname(
            cname.as_ptr(),
            buf.as_mut_ptr() as *mut c_void,
            &mut size,
            ptr::null_mut(),
            0,
        ) != 0
        {
            return None;
        }
        buf.truncate(size);
        while buf.last() == Some(&0) {
            buf.pop();
        }
        String::from_utf8(buf).ok()
    }
}

pub fn sysctl_scalar<T: Copy>(name: &str) -> Option<T> {
    let cname = CString::new(name).ok()?;
    let mut value = std::mem::MaybeUninit::<T>::uninit();
    let mut size = std::mem::size_of::<T>();
    unsafe {
        if libc::sysctlbyname(
            cname.as_ptr(),
            value.as_mut_ptr() as *mut c_void,
            &mut size,
            ptr::null_mut(),
            0,
        ) != 0
            || size != std::mem::size_of::<T>()
        {
            return None;
        }
        Some(value.assume_init())
    }
}

/// Reads a sysctl identified by a MIB into a freshly sized byte buffer.
pub fn sysctl_mib_bytes(mib: &mut [i32]) -> Option<Vec<u8>> {
    let mut size: usize = 0;
    unsafe {
        if libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            ptr::null_mut(),
            &mut size,
            ptr::null_mut(),
            0,
        ) != 0
            || size == 0
        {
            return None;
        }
        let mut buf = vec![0u8; size];
        if libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            buf.as_mut_ptr() as *mut c_void,
            &mut size,
            ptr::null_mut(),
            0,
        ) != 0
        {
            return None;
        }
        buf.truncate(size);
        Some(buf)
    }
}

pub fn page_size() -> u64 {
    unsafe { libc::sysconf(libc::_SC_PAGESIZE).max(4096) as u64 }
}

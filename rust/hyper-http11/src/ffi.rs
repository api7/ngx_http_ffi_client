use libc::{c_char, size_t};
use std::slice;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct FfiStr {
    pub data: *const u8,
    pub len: size_t,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct FfiHeader {
    pub key: FfiStr,
    pub value: FfiStr,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct FfiReq {
    pub scheme: FfiStr,
    pub host: FfiStr,
    pub port: u16,
    pub method: FfiStr,
    pub path: FfiStr,
    pub headers: *const FfiHeader,
    pub headers_len: size_t,
    pub body: FfiStr,
    pub keepalive_pool: FfiStr,
    pub keepalive: bool,
    pub keepalive_idle_timeout: u64,
    pub keepalive_pool_size: u64,
    pub connect_timeout: u64,
    pub send_timeout: u64,
    pub read_timeout: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct PollResult {
    pub done: bool,
    pub want_read: bool,
    pub want_write: bool,
    pub error: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct HeaderView {
    pub key: FfiStr,
    pub value: FfiStr,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ErrorView {
    pub data: *const c_char,
    pub len: size_t,
}

pub unsafe fn ffi_str_as_slice(value: FfiStr) -> Result<&'static [u8], String> {
    if value.len == 0 {
        return Ok(&[]);
    }

    if value.data.is_null() {
        return Err("null FfiStr data with non-zero length".to_string());
    }

    Ok(slice::from_raw_parts(value.data, value.len as usize))
}

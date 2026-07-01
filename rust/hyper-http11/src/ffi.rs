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
    pub port: usize,
    pub method: FfiStr,
    pub path: FfiStr,
    pub headers: *const FfiHeader,
    pub headers_len: usize,
    pub body: FfiStr,
    pub keepalive_pool: FfiStr,
    pub keepalive: usize,
    pub keepalive_idle_timeout: usize,
    pub keepalive_pool_size: usize,
    pub connect_timeout: usize,
    pub send_timeout: usize,
    pub read_timeout: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct PollResult {
    pub done: u32,
    pub want_read: u32,
    pub want_write: u32,
    pub error: u32,
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{align_of, offset_of, size_of};

    #[test]
    fn ffi_req_uses_pointer_sized_abi_fields() {
        let ptr = size_of::<usize>();
        assert_eq!(size_of::<FfiStr>(), ptr * 2);
        assert_eq!(size_of::<FfiHeader>(), ptr * 4);
        assert_eq!(align_of::<FfiReq>(), ptr);

        assert_eq!(offset_of!(FfiReq, scheme), 0);
        assert_eq!(offset_of!(FfiReq, host), ptr * 2);
        assert_eq!(offset_of!(FfiReq, port), ptr * 4);
        assert_eq!(offset_of!(FfiReq, method), ptr * 5);
        assert_eq!(offset_of!(FfiReq, path), ptr * 7);
        assert_eq!(offset_of!(FfiReq, headers), ptr * 9);
        assert_eq!(offset_of!(FfiReq, headers_len), ptr * 10);
        assert_eq!(offset_of!(FfiReq, body), ptr * 11);
        assert_eq!(offset_of!(FfiReq, keepalive_pool), ptr * 13);
        assert_eq!(offset_of!(FfiReq, keepalive), ptr * 15);
        assert_eq!(offset_of!(FfiReq, keepalive_idle_timeout), ptr * 16);
        assert_eq!(offset_of!(FfiReq, keepalive_pool_size), ptr * 17);
        assert_eq!(offset_of!(FfiReq, connect_timeout), ptr * 18);
        assert_eq!(offset_of!(FfiReq, send_timeout), ptr * 19);
        assert_eq!(offset_of!(FfiReq, read_timeout), ptr * 20);
        assert_eq!(size_of::<FfiReq>(), ptr * 21);
    }

    #[test]
    fn poll_result_uses_four_u32_fields() {
        assert_eq!(size_of::<PollResult>(), size_of::<u32>() * 4);
        assert_eq!(align_of::<PollResult>(), align_of::<u32>());
        assert_eq!(offset_of!(PollResult, done), 0);
        assert_eq!(offset_of!(PollResult, want_read), 4);
        assert_eq!(offset_of!(PollResult, want_write), 8);
        assert_eq!(offset_of!(PollResult, error), 12);
    }
}

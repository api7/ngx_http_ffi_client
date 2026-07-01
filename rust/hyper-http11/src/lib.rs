pub mod engine;
pub mod ffi;
mod io;
mod waker;

use crate::engine::Engine;
use crate::ffi::{ErrorView, FfiReq, FfiStr, HeaderView, PollResult};
use libc::{c_uchar, size_t};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_new(req: *const FfiReq) -> *mut Engine {
    match catch_unwind(AssertUnwindSafe(|| Engine::new(req))) {
        Ok(Ok(engine)) => Box::into_raw(Box::new(engine)),
        _ => ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_free(engine: *mut Engine) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !engine.is_null() {
            drop(Box::from_raw(engine));
        }
    }));
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_feed(
    engine: *mut Engine,
    data: *const u8,
    len: size_t,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(engine) = engine.as_mut() else {
            return -1;
        };
        let data = if len == 0 {
            &[]
        } else if data.is_null() {
            return -1;
        } else {
            slice::from_raw_parts(data, len as usize)
        };
        engine.feed(data);
        0
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_poll(
    engine: *mut Engine,
    result: *mut PollResult,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(engine), Some(result)) = (engine.as_mut(), result.as_mut()) else {
            return -1;
        };

        *result = engine.poll();
        0
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_output(
    engine: *const Engine,
    data: *mut *const c_uchar,
    len: *mut size_t,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(engine), Some(data), Some(len)) = (engine.as_ref(), data.as_mut(), len.as_mut())
        else {
            return -1;
        };

        *data = engine.output_ptr().cast();
        *len = engine.output_len();
        0
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_consume_output(
    engine: *mut Engine,
    n: size_t,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(engine) = engine.as_mut() else {
            return -1;
        };

        engine.consume_output(n as usize);
        0
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_status(engine: *const Engine) -> u16 {
    catch_unwind(AssertUnwindSafe(|| {
        engine
            .as_ref()
            .and_then(Engine::response)
            .map(|response| response.status)
            .unwrap_or(0)
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_header_count(engine: *const Engine) -> size_t {
    catch_unwind(AssertUnwindSafe(|| {
        engine
            .as_ref()
            .and_then(Engine::response)
            .map(|response| response.headers.len())
            .unwrap_or(0)
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_header(
    engine: *const Engine,
    idx: size_t,
    out: *mut HeaderView,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(engine), Some(out)) = (engine.as_ref(), out.as_mut()) else {
            return -1;
        };
        let Some(header) = engine.header(idx as usize) else {
            return -1;
        };

        *out = header;
        0
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_body(
    engine: *const Engine,
    out: *mut FfiStr,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(engine), Some(out)) = (engine.as_ref(), out.as_mut()) else {
            return -1;
        };

        *out = engine.body_view();
        0
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_connection_close(engine: *const Engine) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        engine
            .as_ref()
            .and_then(Engine::response)
            .map(|response| response.connection_close)
            .unwrap_or(false)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_error(
    engine: *const Engine,
    out: *mut ErrorView,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(engine), Some(out)) = (engine.as_ref(), out.as_mut()) else {
            return -1;
        };

        let bytes = engine.error_bytes();
        *out = ErrorView {
            data: bytes.as_ptr().cast(),
            len: bytes.len(),
        };
        0
    }))
    .unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use libc::c_uchar;

    #[test]
    fn ffi_wrappers_reject_null_out_parameters() {
        unsafe {
            let mut data: *const c_uchar = ptr::null();
            let mut len: size_t = 0;

            assert_eq!(
                ngx_http_ffi_client_hyper_feed(ptr::null_mut(), ptr::null(), 0),
                -1
            );
            assert_eq!(
                ngx_http_ffi_client_hyper_poll(ptr::null_mut(), ptr::null_mut()),
                -1
            );
            assert_eq!(
                ngx_http_ffi_client_hyper_output(ptr::null(), &mut data, ptr::null_mut()),
                -1
            );
            assert_eq!(
                ngx_http_ffi_client_hyper_output(ptr::null(), ptr::null_mut(), &mut len),
                -1
            );
            assert_eq!(
                ngx_http_ffi_client_hyper_consume_output(ptr::null_mut(), 0),
                -1
            );
            assert_eq!(
                ngx_http_ffi_client_hyper_header(ptr::null(), 0, ptr::null_mut()),
                -1
            );
            assert_eq!(
                ngx_http_ffi_client_hyper_body(ptr::null(), ptr::null_mut()),
                -1
            );
            assert_eq!(
                ngx_http_ffi_client_hyper_error(ptr::null(), ptr::null_mut()),
                -1
            );
        }
    }
}

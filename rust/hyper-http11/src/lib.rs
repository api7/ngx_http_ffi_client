pub mod engine;
pub mod ffi;
mod io;
mod waker;

use crate::engine::Engine;
use crate::ffi::{ErrorView, FfiReq, FfiStr, HeaderView, PollResult};
use libc::size_t;
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
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(engine) = engine.as_mut() {
            let data = if len == 0 {
                &[]
            } else if data.is_null() {
                return;
            } else {
                slice::from_raw_parts(data, len as usize)
            };
            engine.feed(data);
        }
    }));
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_poll(engine: *mut Engine) -> PollResult {
    catch_unwind(AssertUnwindSafe(|| {
        engine.as_mut().map(Engine::poll).unwrap_or(PollResult {
            error: true,
            ..PollResult::default()
        })
    }))
    .unwrap_or(PollResult {
        error: true,
        ..PollResult::default()
    })
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_output(
    engine: *const Engine,
    len: *mut size_t,
) -> *const u8 {
    catch_unwind(AssertUnwindSafe(|| {
        if engine.is_null() {
            if let Some(len) = len.as_mut() {
                *len = 0;
            }
            return ptr::null();
        }
        let engine = &*engine;
        if let Some(len) = len.as_mut() {
            *len = engine.output_len();
        }
        engine.output_ptr()
    }))
    .unwrap_or(ptr::null())
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_consume_output(engine: *mut Engine, n: size_t) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(engine) = engine.as_mut() {
            engine.consume_output(n as usize);
        }
    }));
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
) -> HeaderView {
    catch_unwind(AssertUnwindSafe(|| {
        engine
            .as_ref()
            .and_then(|engine| engine.header(idx as usize))
            .unwrap_or(HeaderView {
                key: FfiStr {
                    data: ptr::null(),
                    len: 0,
                },
                value: FfiStr {
                    data: ptr::null(),
                    len: 0,
                },
            })
    }))
    .unwrap_or(HeaderView {
        key: FfiStr {
            data: ptr::null(),
            len: 0,
        },
        value: FfiStr {
            data: ptr::null(),
            len: 0,
        },
    })
}

#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_body(engine: *const Engine) -> FfiStr {
    catch_unwind(AssertUnwindSafe(|| {
        engine.as_ref().map(Engine::body_view).unwrap_or(FfiStr {
            data: ptr::null(),
            len: 0,
        })
    }))
    .unwrap_or(FfiStr {
        data: ptr::null(),
        len: 0,
    })
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
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_error(engine: *const Engine) -> ErrorView {
    catch_unwind(AssertUnwindSafe(|| {
        let bytes = engine
            .as_ref()
            .map(Engine::error_bytes)
            .unwrap_or("null engine".as_bytes());
        ErrorView {
            data: bytes.as_ptr().cast(),
            len: bytes.len(),
        }
    }))
    .unwrap_or(ErrorView {
        data: ptr::null(),
        len: 0,
    })
}

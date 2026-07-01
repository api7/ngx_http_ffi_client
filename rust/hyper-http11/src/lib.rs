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

// POC FFI contract:
// - Engine pointers must be used serially on one Nginx worker thread.
// - No concurrent FFI calls are supported for the same engine pointer.
// - Output/body/header/error views are borrowed from the engine. They are valid
//   only while the engine is alive and until the next mutating FFI call or free.
//   C callers must copy view bytes before poll/feed/consume/close_read/free.

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
        } else if len > isize::MAX as size_t {
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
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_close_read(engine: *mut Engine) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(engine) = engine.as_mut() else {
            return -1;
        };

        engine.close_read();
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

// Returns a borrowed output buffer view. The pointer is valid only until the
// next mutating FFI call or free; callers must copy before consuming output.
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

// Returns a borrowed header view. Header views are available only after done.
// The returned pointers are valid only until the next mutating FFI call or free.
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
        if !engine.done() {
            return -1;
        }
        let Some(header) = engine.header(idx as usize) else {
            return -1;
        };

        *out = header;
        0
    }))
    .unwrap_or(-1)
}

// Returns a borrowed response body view. Body views are available only after
// done. The returned pointer is valid only until the next mutating FFI call or
// free.
#[no_mangle]
pub unsafe extern "C" fn ngx_http_ffi_client_hyper_body(
    engine: *const Engine,
    out: *mut FfiStr,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(engine), Some(out)) = (engine.as_ref(), out.as_mut()) else {
            return -1;
        };
        if !engine.done() {
            return -1;
        }

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

// Returns a borrowed error message view. The pointer is valid only until the
// next mutating FFI call or free.
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
    use pretty_assertions::assert_eq;

    struct TestReq {
        scheme: Vec<u8>,
        host: Vec<u8>,
        method: Vec<u8>,
        path: Vec<u8>,
        body: Vec<u8>,
        _header_storage: Vec<(Vec<u8>, Vec<u8>)>,
        headers: Vec<crate::ffi::FfiHeader>,
        req: FfiReq,
    }

    impl TestReq {
        fn new(method: &str, path: &str, body: &[u8], headers: &[(&str, &str)]) -> Self {
            let scheme = b"http".to_vec();
            let host = b"example.com".to_vec();
            let method = method.as_bytes().to_vec();
            let path = path.as_bytes().to_vec();
            let body = body.to_vec();
            let header_storage = headers
                .iter()
                .map(|(key, value)| (key.as_bytes().to_vec(), value.as_bytes().to_vec()))
                .collect::<Vec<_>>();
            let headers = header_storage
                .iter()
                .map(|(key, value)| crate::ffi::FfiHeader {
                    key: ffi_str(key),
                    value: ffi_str(value),
                })
                .collect::<Vec<_>>();

            let mut test_req = Self {
                scheme,
                host,
                method,
                path,
                body,
                _header_storage: header_storage,
                headers,
                req: empty_req(),
            };
            test_req.rebuild();
            test_req
        }

        fn rebuild(&mut self) {
            self.req = FfiReq {
                scheme: ffi_str(&self.scheme),
                host: ffi_str(&self.host),
                port: 80,
                method: ffi_str(&self.method),
                path: ffi_str(&self.path),
                headers: self.headers.as_ptr(),
                headers_len: self.headers.len(),
                body: ffi_str(&self.body),
                keepalive_pool: FfiStr {
                    data: ptr::null(),
                    len: 0,
                },
                keepalive: 0,
                keepalive_idle_timeout: 0,
                keepalive_pool_size: 0,
                connect_timeout: 0,
                send_timeout: 0,
                read_timeout: 0,
            };
        }
    }

    fn empty_req() -> FfiReq {
        FfiReq {
            scheme: FfiStr {
                data: ptr::null(),
                len: 0,
            },
            host: FfiStr {
                data: ptr::null(),
                len: 0,
            },
            port: 0,
            method: FfiStr {
                data: ptr::null(),
                len: 0,
            },
            path: FfiStr {
                data: ptr::null(),
                len: 0,
            },
            headers: ptr::null(),
            headers_len: 0,
            body: FfiStr {
                data: ptr::null(),
                len: 0,
            },
            keepalive_pool: FfiStr {
                data: ptr::null(),
                len: 0,
            },
            keepalive: 0,
            keepalive_idle_timeout: 0,
            keepalive_pool_size: 0,
            connect_timeout: 0,
            send_timeout: 0,
            read_timeout: 0,
        }
    }

    fn ffi_str(bytes: &[u8]) -> FfiStr {
        FfiStr {
            data: bytes.as_ptr(),
            len: bytes.len(),
        }
    }

    unsafe fn new_engine(req: &TestReq) -> *mut Engine {
        let engine = ngx_http_ffi_client_hyper_new(&req.req);
        assert!(!engine.is_null());
        engine
    }

    unsafe fn poll_engine(engine: *mut Engine) -> PollResult {
        let mut result = PollResult::default();
        assert_eq!(ngx_http_ffi_client_hyper_poll(engine, &mut result), 0);
        result
    }

    unsafe fn output_bytes(engine: *mut Engine) -> Vec<u8> {
        let mut data: *const c_uchar = ptr::null();
        let mut len: size_t = 0;
        assert_eq!(
            ngx_http_ffi_client_hyper_output(engine, &mut data, &mut len),
            0
        );
        if len == 0 {
            return Vec::new();
        }
        assert!(!data.is_null());
        slice::from_raw_parts(data, len).to_vec()
    }

    unsafe fn finish_text_response(engine: *mut Engine) {
        assert_eq!(
            ngx_http_ffi_client_hyper_consume_output(engine, output_bytes(engine).len()),
            0
        );
        let response = b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nX-Resp: ok\r\nConnection: keep-alive\r\n\r\ndone";
        assert_eq!(
            ngx_http_ffi_client_hyper_feed(engine, response.as_ptr(), response.len()),
            0
        );
        for _ in 0..8 {
            if poll_engine(engine).done != 0 {
                break;
            }
        }
    }

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
            assert_eq!(ngx_http_ffi_client_hyper_close_read(ptr::null_mut()), -1);
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

    #[test]
    fn ffi_feed_rejects_oversized_buffer_length() {
        unsafe {
            let req = TestReq::new("GET", "/oversized", b"", &[]);
            let engine = new_engine(&req);
            let byte = 0_u8;

            assert_eq!(
                ngx_http_ffi_client_hyper_feed(engine, &byte, isize::MAX as size_t + 1,),
                -1
            );

            ngx_http_ffi_client_hyper_free(engine);
        }
    }

    #[test]
    fn ffi_close_read_drives_eof_response_path() {
        unsafe {
            let req = TestReq::new("GET", "/eof", b"", &[]);
            let engine = new_engine(&req);

            let _ = poll_engine(engine);
            assert_eq!(
                ngx_http_ffi_client_hyper_consume_output(engine, output_bytes(engine).len()),
                0
            );
            let response = b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nbody";
            assert_eq!(
                ngx_http_ffi_client_hyper_feed(engine, response.as_ptr(), response.len()),
                0
            );
            assert_eq!(ngx_http_ffi_client_hyper_close_read(engine), 0);

            for _ in 0..8 {
                if poll_engine(engine).done != 0 {
                    break;
                }
            }

            let mut body = FfiStr {
                data: ptr::null(),
                len: 0,
            };
            assert_eq!(ngx_http_ffi_client_hyper_body(engine, &mut body), 0);
            assert_eq!(slice::from_raw_parts(body.data, body.len), b"body");
            ngx_http_ffi_client_hyper_free(engine);
        }
    }

    #[test]
    fn ffi_new_rejects_forbidden_request_framing_headers() {
        unsafe {
            for header in [
                ("Content-Length", "999"),
                ("Transfer-Encoding", "chunked"),
                ("Host", "other.example"),
                ("Connection", "keep-alive"),
            ] {
                let req = TestReq::new("POST", "/submit", b"payload", &[header]);
                let engine = ngx_http_ffi_client_hyper_new(&req.req);
                assert!(engine.is_null(), "{header:?}");
            }
        }
    }

    #[test]
    fn ffi_output_pointer_can_be_copied_before_consume() {
        unsafe {
            let req = TestReq::new("POST", "/submit", b"payload", &[("X-Test", "yes")]);
            let engine = new_engine(&req);

            let _ = poll_engine(engine);
            let written = output_bytes(engine);
            assert!(written.starts_with(b"POST /submit HTTP/1.1\r\n"));
            assert!(written.ends_with(b"\r\npayload"));
            assert_eq!(
                ngx_http_ffi_client_hyper_consume_output(engine, written.len()),
                0
            );
            assert!(output_bytes(engine).is_empty());

            ngx_http_ffi_client_hyper_free(engine);
        }
    }

    #[test]
    fn ffi_body_and_header_are_available_only_after_done() {
        unsafe {
            let req = TestReq::new("GET", "/done", b"", &[]);
            let engine = new_engine(&req);

            let _ = poll_engine(engine);
            let mut body = FfiStr {
                data: ptr::null(),
                len: 0,
            };
            let mut header = HeaderView {
                key: FfiStr {
                    data: ptr::null(),
                    len: 0,
                },
                value: FfiStr {
                    data: ptr::null(),
                    len: 0,
                },
            };

            assert_eq!(ngx_http_ffi_client_hyper_body(engine, &mut body), -1);
            assert_eq!(ngx_http_ffi_client_hyper_header(engine, 0, &mut header), -1);

            finish_text_response(engine);
            assert_eq!(poll_engine(engine).done, 1);

            assert_eq!(ngx_http_ffi_client_hyper_body(engine, &mut body), 0);
            assert_eq!(slice::from_raw_parts(body.data, body.len), b"done");
            assert_eq!(ngx_http_ffi_client_hyper_header(engine, 0, &mut header), 0);
            assert_eq!(
                slice::from_raw_parts(header.key.data, header.key.len),
                b"content-length"
            );
            assert_eq!(
                slice::from_raw_parts(header.value.data, header.value.len),
                b"4"
            );

            ngx_http_ffi_client_hyper_free(engine);
        }
    }
}

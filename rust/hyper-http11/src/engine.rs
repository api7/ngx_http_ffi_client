use crate::ffi::{
    ffi_headers_as_slice, ffi_str_as_slice, FfiHeader, FfiReq, FfiStr, HeaderView, PollResult,
};
use crate::io::BufferedIo;
use crate::waker::noop_waker;
use bytes::{Buf, Bytes};
use http::header::{CONNECTION, CONTENT_LENGTH, HOST, TRANSFER_ENCODING};
use http::{HeaderName, HeaderValue, Request, Response as HttpResponse, Uri};
use http_body_util::Full;
use hyper::body::{Body, Incoming};
use hyper::client::conn::http1;
use std::future::Future;
use std::pin::Pin;
use std::str;
use std::task::{Context, Poll};

type ReqBody = Full<Bytes>;
type ResponseFuture = Pin<Box<dyn Future<Output = hyper::Result<HttpResponse<Incoming>>>>>;

pub struct Response {
    pub status: u16,
    pub headers: Vec<(Vec<u8>, Vec<u8>)>,
    pub body: Vec<u8>,
    pub connection_close: bool,
}

/// Proof-of-concept HTTP/1.1 engine.
///
/// This engine is single-threaded. It must be used serially on one Nginx worker
/// thread, with no concurrent FFI calls for the same engine pointer.
pub struct Engine {
    io: BufferedIo,
    connection: Option<http1::Connection<BufferedIo, ReqBody>>,
    response_future: Option<ResponseFuture>,
    response_body: Option<Incoming>,
    response: Option<Response>,
    complete: bool,
    error: Option<String>,
}

impl Engine {
    pub unsafe fn new(req: *const FfiReq) -> Result<Self, String> {
        if req.is_null() {
            return Err("null request".to_string());
        }

        let request = build_request(&*req)?;
        let io = BufferedIo::new();
        let mut builder = http1::Builder::new();
        builder.title_case_headers(true);
        let mut handshake = Box::pin(builder.handshake(io.clone()));
        let (mut sender, connection) = match with_context(|cx| handshake.as_mut().poll(cx)) {
            Poll::Ready(Ok(parts)) => parts,
            Poll::Ready(Err(err)) => return Err(err.to_string()),
            Poll::Pending => {
                return Err("hyper HTTP/1.1 handshake unexpectedly pending".to_string())
            }
        };
        let response_future = Box::pin(sender.send_request(request));

        Ok(Self {
            io,
            connection: Some(connection),
            response_future: Some(response_future),
            response_body: None,
            response: None,
            complete: false,
            error: None,
        })
    }

    pub fn feed(&mut self, data: &[u8]) {
        self.io.feed(data);
    }

    pub fn close_read(&mut self) {
        self.io.close_read();
    }

    pub fn poll(&mut self) -> PollResult {
        if self.failed() || self.complete {
            return self.poll_result();
        }

        with_context(|cx| {
            self.poll_response_future(cx);
            self.poll_connection(cx);
            self.poll_response_body(cx);
            self.poll_response_future(cx);
            self.poll_connection(cx);
        });

        self.poll_result()
    }

    pub fn output_len(&self) -> usize {
        self.io.output_len()
    }

    pub fn output_ptr(&self) -> *const u8 {
        self.io.output_ptr()
    }

    pub fn consume_output(&mut self, n: usize) {
        self.io.consume_output(n);
    }

    pub fn done(&self) -> bool {
        self.complete && !self.failed()
    }

    pub fn failed(&self) -> bool {
        self.error.is_some()
    }

    pub fn response(&self) -> Option<&Response> {
        self.response.as_ref()
    }

    pub fn error_bytes(&self) -> &[u8] {
        self.error.as_deref().unwrap_or("").as_bytes()
    }

    pub fn header(&self, _idx: usize) -> Option<HeaderView> {
        let (key, value) = self.response.as_ref()?.headers.get(_idx)?;
        Some(HeaderView {
            key: FfiStr {
                data: key.as_ptr(),
                len: key.len(),
            },
            value: FfiStr {
                data: value.as_ptr(),
                len: value.len(),
            },
        })
    }

    pub fn body_view(&self) -> FfiStr {
        if let Some(response) = self.response.as_ref() {
            return FfiStr {
                data: response.body.as_ptr(),
                len: response.body.len(),
            };
        }

        FfiStr {
            data: std::ptr::null(),
            len: 0,
        }
    }

    fn poll_response_future(&mut self, cx: &mut Context<'_>) {
        let Some(response_future) = self.response_future.as_mut() else {
            return;
        };

        match response_future.as_mut().poll(cx) {
            Poll::Ready(Ok(response)) => {
                self.response_future = None;
                let (parts, body) = response.into_parts();
                let headers = parts
                    .headers
                    .iter()
                    .map(|(key, value)| {
                        (key.as_str().as_bytes().to_vec(), value.as_bytes().to_vec())
                    })
                    .collect();
                let connection_close = parts
                    .headers
                    .get(CONNECTION)
                    .and_then(|value| value.to_str().ok())
                    .map(connection_has_close)
                    .unwrap_or(false);

                self.response = Some(Response {
                    status: parts.status.as_u16(),
                    headers,
                    body: Vec::new(),
                    connection_close,
                });
                self.response_body = Some(body);
            }
            Poll::Ready(Err(err)) => self.fail(err.to_string()),
            Poll::Pending => {}
        }
    }

    fn poll_response_body(&mut self, cx: &mut Context<'_>) {
        let Some(body) = self.response_body.as_mut() else {
            return;
        };

        loop {
            match Pin::new(&mut *body).poll_frame(cx) {
                Poll::Ready(Some(Ok(frame))) => {
                    if let Ok(mut data) = frame.into_data() {
                        if let Some(response) = self.response.as_mut() {
                            while data.has_remaining() {
                                let chunk = data.chunk();
                                response.body.extend_from_slice(chunk);
                                let len = chunk.len();
                                data.advance(len);
                            }
                        }
                    }
                }
                Poll::Ready(Some(Err(err))) => {
                    self.fail(err.to_string());
                    return;
                }
                Poll::Ready(None) => {
                    self.response_body = None;
                    self.complete = self.response.is_some();
                    return;
                }
                Poll::Pending => return,
            }
        }
    }

    fn poll_connection(&mut self, cx: &mut Context<'_>) {
        let Some(connection) = self.connection.as_mut() else {
            return;
        };

        match Pin::new(connection).poll(cx) {
            Poll::Ready(Ok(())) => {
                self.connection = None;
                if self.response_future.is_none()
                    && self.response_body.is_none()
                    && self.response.is_some()
                {
                    self.complete = true;
                }
            }
            Poll::Ready(Err(err)) => {
                if self.response.is_none() {
                    self.fail(err.to_string());
                } else {
                    self.connection = None;
                }
            }
            Poll::Pending => {}
        }
    }

    fn poll_result(&self) -> PollResult {
        PollResult {
            done: flag(self.done()),
            want_read: flag(!self.done() && !self.failed() && self.output_len() == 0),
            want_write: flag(!self.failed() && self.output_len() > 0),
            error: flag(self.failed()),
        }
    }

    fn fail(&mut self, error: String) {
        self.error = Some(error);
        self.response_future = None;
        self.response_body = None;
        self.connection = None;
        self.complete = false;
    }
}

fn build_request(req: &FfiReq) -> Result<Request<ReqBody>, String> {
    let method = ffi_string(req.method, "method")?;
    let path = ffi_string(req.path, "path")?;
    let scheme = ffi_string(req.scheme, "scheme")?;
    let host = ffi_string(req.host, "host")?;
    let body = unsafe { ffi_str_as_slice(req.body) }?.to_vec();
    let uri = path.parse::<Uri>().map_err(|err| err.to_string())?;

    let mut request = Request::builder()
        .method(method.as_str())
        .uri(uri)
        .body(Full::new(Bytes::from(body.clone())))
        .map_err(|err| err.to_string())?;

    let headers = request.headers_mut();
    for header in ffi_headers(req)? {
        let key = unsafe { ffi_str_as_slice(header.key) }?;
        let value = unsafe { ffi_str_as_slice(header.value) }?;
        let name = HeaderName::from_bytes(key).map_err(|err| err.to_string())?;
        let header_value = HeaderValue::from_bytes(value).map_err(|err| err.to_string())?;

        if is_engine_managed_request_header(&name) {
            return Err(format!("request header is managed by engine: {name}"));
        }

        headers.append(name, header_value);
    }

    headers.insert(
        HOST,
        HeaderValue::from_str(&host_header(&scheme, &host, req.port))
            .map_err(|err| err.to_string())?,
    );

    if !body.is_empty() {
        headers.insert(
            CONTENT_LENGTH,
            HeaderValue::from_str(&body.len().to_string()).map_err(|err| err.to_string())?,
        );
    }

    let value = if req.keepalive != 0 {
        "keep-alive"
    } else {
        "close"
    };
    headers.insert(CONNECTION, HeaderValue::from_static(value));

    Ok(request)
}

fn ffi_string(value: FfiStr, name: &str) -> Result<String, String> {
    let bytes = unsafe { ffi_str_as_slice(value) }?;
    str::from_utf8(bytes)
        .map(|value| value.to_string())
        .map_err(|err| format!("invalid {name}: {err}"))
}

fn ffi_headers(req: &FfiReq) -> Result<&[FfiHeader], String> {
    unsafe { ffi_headers_as_slice(req.headers, req.headers_len) }
}

fn host_header(scheme: &str, host: &str, port: usize) -> String {
    if port == 0 || (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
        host.to_string()
    } else {
        format!("{host}:{port}")
    }
}

fn flag(value: bool) -> u32 {
    u32::from(value)
}

fn is_engine_managed_request_header(name: &HeaderName) -> bool {
    name == HOST || name == CONNECTION || name == CONTENT_LENGTH || name == TRANSFER_ENCODING
}

fn connection_has_close(value: &str) -> bool {
    value
        .split(',')
        .any(|token| token.trim().eq_ignore_ascii_case("close"))
}

fn with_context<T>(f: impl FnOnce(&mut Context<'_>) -> T) -> T {
    let waker = noop_waker();
    let mut cx = Context::from_waker(&waker);
    f(&mut cx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::{FfiHeader, FfiReq};
    use pretty_assertions::assert_eq;
    use std::slice;

    struct TestReq {
        scheme: Vec<u8>,
        host: Vec<u8>,
        method: Vec<u8>,
        path: Vec<u8>,
        body: Vec<u8>,
        _header_storage: Vec<(Vec<u8>, Vec<u8>)>,
        headers: Vec<FfiHeader>,
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
                .map(|(key, value)| FfiHeader {
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
                    data: std::ptr::null(),
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
                data: std::ptr::null(),
                len: 0,
            },
            host: FfiStr {
                data: std::ptr::null(),
                len: 0,
            },
            port: 0,
            method: FfiStr {
                data: std::ptr::null(),
                len: 0,
            },
            path: FfiStr {
                data: std::ptr::null(),
                len: 0,
            },
            headers: std::ptr::null(),
            headers_len: 0,
            body: FfiStr {
                data: std::ptr::null(),
                len: 0,
            },
            keepalive_pool: FfiStr {
                data: std::ptr::null(),
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

    fn output(engine: &Engine) -> &[u8] {
        unsafe { slice::from_raw_parts(engine.output_ptr(), engine.output_len()) }
    }

    #[test]
    fn emits_post_request_bytes_with_headers_and_body() {
        let req = TestReq::new("POST", "/submit", b"payload", &[("X-Test", "yes")]);
        let mut engine = unsafe { Engine::new(&req.req) }.expect("engine");

        let poll = engine.poll();

        assert_eq!(poll.error, 0);
        let written = output(&engine);
        assert!(
            written.starts_with(b"POST /submit HTTP/1.1\r\n"),
            "{}",
            String::from_utf8_lossy(written)
        );
        assert!(
            written
                .windows(b"Host: example.com\r\n".len())
                .any(|window| window == b"Host: example.com\r\n"),
            "{}",
            String::from_utf8_lossy(written)
        );
        assert!(
            written
                .windows(b"X-Test: yes\r\n".len())
                .any(|window| window == b"X-Test: yes\r\n"),
            "{}",
            String::from_utf8_lossy(written)
        );
        assert!(
            written.ends_with(b"\r\npayload"),
            "{}",
            String::from_utf8_lossy(written)
        );
    }

    #[test]
    fn parses_chunked_response_body() {
        let req = TestReq::new("GET", "/chunked", b"", &[]);
        let mut engine = unsafe { Engine::new(&req.req) }.expect("engine");

        let _ = engine.poll();
        engine.consume_output(engine.output_len());
        engine.feed(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive, close\r\n\r\n7\r\nchunked\r\n0\r\n\r\n",
        );
        engine.close_read();

        for _ in 0..8 {
            if engine.poll().done != 0 {
                break;
            }
        }

        assert!(engine.done());
        let response = engine.response().expect("response");
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"chunked");
        assert!(response.connection_close);
    }
}

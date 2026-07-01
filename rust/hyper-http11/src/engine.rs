use crate::ffi::{
    ffi_headers_as_slice, ffi_str_as_slice, FfiHeader, FfiReq, FfiStr, HeaderView, PollResult,
};
use crate::io::BufferedIo;
use crate::waker::noop_waker;
use bytes::{Buf, Bytes};
use http::header::{CONNECTION, CONTENT_LENGTH, HOST, TRANSFER_ENCODING};
use http::{HeaderMap, HeaderName, HeaderValue, Request, Response as HttpResponse, Uri, Version};
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
    sender: Option<http1::SendRequest<ReqBody>>,
    connection: Option<http1::Connection<BufferedIo, ReqBody>>,
    response_future: Option<ResponseFuture>,
    response_body: Option<Incoming>,
    response: Option<Response>,
    detached_read_buf_empty: Option<bool>,
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
            sender: Some(sender),
            connection: Some(connection),
            response_future: Some(response_future),
            response_body: None,
            response: None,
            detached_read_buf_empty: None,
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
            self.poll_response_body(cx);
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

    pub fn mark_keepalive_reusable_for_bench(&mut self) -> bool {
        if !self.done() || self.output_len() != 0 || self.io.input_len() != 0 {
            return false;
        }

        let Some(response) = self.response.as_ref() else {
            return false;
        };

        if response.connection_close {
            return false;
        }

        let read_buf_empty = if let Some(connection) = self.connection.take() {
            let parts = connection.into_parts();
            let read_buf_empty = parts.read_buf.is_empty();
            self.io = parts.io;
            self.detached_read_buf_empty = Some(read_buf_empty);
            read_buf_empty
        } else {
            self.detached_read_buf_empty.unwrap_or(false)
        };

        read_buf_empty && self.io.input_len() == 0 && self.io.output_len() == 0
    }

    pub fn mark_session_reusable_for_bench(&self) -> bool {
        if !self.done()
            || self.output_len() != 0
            || self.io.input_len() != 0
            || self.response_future.is_some()
            || self.response_body.is_some()
        {
            return false;
        }

        let Some(response) = self.response.as_ref() else {
            return false;
        };

        if response.connection_close {
            return false;
        }

        let Some(sender) = self.sender.as_ref() else {
            return false;
        };

        !sender.is_closed() && self.connection.is_some()
    }

    pub unsafe fn start_request(&mut self, req: *const FfiReq) -> Result<(), String> {
        if req.is_null() {
            return Err("null request".to_string());
        }

        if !self.mark_session_reusable_for_bench() {
            return Err("hyper session is not reusable".to_string());
        }

        let request = build_request(&*req)?;

        let ready = with_context(|cx| match self.poll_sender_ready(cx) {
            Poll::Ready(Ok(())) => Ok(true),
            Poll::Ready(Err(err)) => Err(err),
            Poll::Pending => {
                self.poll_connection(cx);
                match self.poll_sender_ready(cx) {
                    Poll::Ready(Ok(())) => Ok(true),
                    Poll::Ready(Err(err)) => Err(err),
                    Poll::Pending => Ok(false),
                }
            }
        })?;

        if !ready {
            return Err("hyper sender is not ready".to_string());
        }

        let Some(sender) = self.sender.as_mut() else {
            return Err("hyper sender is missing".to_string());
        };

        self.response_future = Some(Box::pin(sender.send_request(request)));
        self.response_body = None;
        self.response = None;
        self.detached_read_buf_empty = None;
        self.complete = false;
        self.error = None;

        Ok(())
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
                let connection_close = connection_should_close(parts.version, &parts.headers);

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
                let connection = self.connection.take().expect("connection");
                let parts = connection.into_parts();
                self.detached_read_buf_empty = Some(parts.read_buf.is_empty());
                self.io = parts.io;
                self.sender = None;

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
                    self.sender = None;
                }
            }
            Poll::Pending => {}
        }
    }

    fn poll_sender_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), String>> {
        let Some(sender) = self.sender.as_mut() else {
            return Poll::Ready(Err("hyper sender is missing".to_string()));
        };

        match sender.poll_ready(cx) {
            Poll::Ready(Ok(())) => Poll::Ready(Ok(())),
            Poll::Ready(Err(err)) => Poll::Ready(Err(err.to_string())),
            Poll::Pending => Poll::Pending,
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
        self.sender = None;
        self.detached_read_buf_empty = Some(false);
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
    let formatted_host = if host.contains(':') && !(host.starts_with('[') && host.ends_with(']')) {
        format!("[{host}]")
    } else {
        host.to_string()
    };

    if port == 0 || (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
        formatted_host
    } else {
        format!("{formatted_host}:{port}")
    }
}

fn flag(value: bool) -> u32 {
    u32::from(value)
}

fn is_engine_managed_request_header(name: &HeaderName) -> bool {
    name == HOST || name == CONNECTION || name == CONTENT_LENGTH || name == TRANSFER_ENCODING
}

fn connection_should_close(version: Version, headers: &HeaderMap) -> bool {
    match version {
        Version::HTTP_10 => !connection_has_token(headers, "keep-alive"),
        _ => connection_has_token(headers, "close"),
    }
}

fn connection_has_token(headers: &HeaderMap, needle: &str) -> bool {
    headers
        .get_all(CONNECTION)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .any(|value| connection_has_token_value(value, needle))
}

fn connection_has_token_value(value: &str, needle: &str) -> bool {
    value
        .split(',')
        .any(|token| token.trim().eq_ignore_ascii_case(needle))
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

    fn finish_response(engine: &mut Engine, response: &[u8]) {
        let _ = engine.poll();
        engine.consume_output(engine.output_len());
        engine.feed(response);

        for _ in 0..8 {
            if engine.poll().done != 0 {
                return;
            }
        }
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
    fn formats_ipv6_host_header_with_brackets() {
        let mut req = TestReq::new("GET", "/ipv6", b"", &[]);
        req.host = b"::1".to_vec();
        req.rebuild();
        req.req.port = 8080;
        let mut engine = unsafe { Engine::new(&req.req) }.expect("engine");

        let poll = engine.poll();

        assert_eq!(poll.error, 0);
        let written = output(&engine);
        assert!(
            written
                .windows(b"Host: [::1]:8080\r\n".len())
                .any(|window| window == b"Host: [::1]:8080\r\n"),
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

    #[test]
    fn completes_chunked_response_before_read_close() {
        let req = TestReq::new("GET", "/chunked", b"", &[]);
        let mut engine = unsafe { Engine::new(&req.req) }.expect("engine");

        let _ = engine.poll();
        engine.consume_output(engine.output_len());
        engine.feed(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n7\r\nchunked\r\n0\r\n\r\n",
        );

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

    #[test]
    fn completes_chunked_response_with_wrapper_poll_sequence() {
        let req = TestReq::new("GET", "/chunked", b"", &[]);
        let mut engine = unsafe { Engine::new(&req.req) }.expect("engine");

        let _ = engine.poll();
        engine.consume_output(engine.output_len());
        engine.feed(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n7\r\nchunked\r\n0\r\n\r\n",
        );

        let _ = engine.poll();
        engine.close_read();
        let poll = engine.poll();

        assert_eq!(poll.done, 1);
        let response = engine.response().expect("response");
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"chunked");
        assert!(response.connection_close);
    }

    #[test]
    fn connection_close_follows_http_version_defaults() {
        for (raw, expected) in [
            (
                b"HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n".as_slice(),
                true,
            ),
            (
                b"HTTP/1.0 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
                    .as_slice(),
                false,
            ),
            (
                b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".as_slice(),
                false,
            ),
            (
                b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".as_slice(),
                true,
            ),
        ] {
            let req = TestReq::new("GET", "/version", b"", &[]);
            let mut engine = unsafe { Engine::new(&req.req) }.expect("engine");

            let _ = engine.poll();
            engine.consume_output(engine.output_len());
            engine.feed(raw);

            for _ in 0..8 {
                if engine.poll().done != 0 {
                    break;
                }
            }

            assert!(engine.done(), "{}", String::from_utf8_lossy(raw));
            let response = engine.response().expect("response");
            assert_eq!(
                response.connection_close,
                expected,
                "{}",
                String::from_utf8_lossy(raw)
            );
        }
    }

    #[test]
    fn benchmark_keepalive_reusable_after_clean_response() {
        let mut req = TestReq::new("GET", "/clean", b"", &[]);
        req.req.keepalive = 1;
        let mut engine = unsafe { Engine::new(&req.req) }.expect("engine");

        finish_response(&mut engine, b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");

        assert!(engine.done());
        assert!(engine.mark_keepalive_reusable_for_bench());
    }

    #[test]
    fn benchmark_keepalive_rejects_protocol_residue() {
        let mut req = TestReq::new("GET", "/dirty", b"", &[]);
        req.req.keepalive = 1;
        let mut engine = unsafe { Engine::new(&req.req) }.expect("engine");

        finish_response(
            &mut engine,
            b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokHTTP/1.1",
        );

        assert!(!engine.mark_keepalive_reusable_for_bench());
    }

    #[test]
    fn benchmark_session_reuses_connection_for_second_request() {
        let mut first = TestReq::new("GET", "/one", b"", &[]);
        first.req.keepalive = 1;
        let mut engine = unsafe { Engine::new(&first.req) }.expect("engine");

        finish_response(
            &mut engine,
            b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none",
        );

        assert!(engine.done());
        assert!(engine.mark_session_reusable_for_bench());

        let mut second = TestReq::new("GET", "/two", b"", &[]);
        second.req.keepalive = 1;
        unsafe { engine.start_request(&second.req) }.expect("second request");

        let poll = engine.poll();
        assert_eq!(poll.error, 0);
        let written = output(&engine);
        assert!(
            written.starts_with(b"GET /two HTTP/1.1\r\n"),
            "{}",
            String::from_utf8_lossy(written)
        );

        finish_response(
            &mut engine,
            b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo",
        );

        assert!(engine.done());
        assert_eq!(engine.response().expect("response").body, b"two");
        assert!(engine.mark_session_reusable_for_bench());
    }
}

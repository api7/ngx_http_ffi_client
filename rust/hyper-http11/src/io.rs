use hyper::rt::{Read, ReadBufCursor, Write};
use std::cell::RefCell;
use std::cmp;
use std::collections::VecDeque;
use std::io;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Context, Poll, Waker};

#[derive(Clone, Debug, Default)]
pub struct BufferedIo {
    inner: Rc<RefCell<BufferedIoInner>>,
}

#[derive(Debug, Default)]
struct BufferedIoInner {
    input: VecDeque<u8>,
    output: Vec<u8>,
    read_closed: bool,
    read_waker: Option<Waker>,
}

impl BufferedIo {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn feed(&self, data: &[u8]) {
        let waker = {
            let mut inner = self.inner.borrow_mut();
            inner.input.extend(data);
            inner.read_waker.take()
        };
        if let Some(waker) = waker {
            waker.wake();
        }
    }

    pub fn close_read(&self) {
        let waker = {
            let mut inner = self.inner.borrow_mut();
            inner.read_closed = true;
            inner.read_waker.take()
        };
        if let Some(waker) = waker {
            waker.wake();
        }
    }

    pub fn output_len(&self) -> usize {
        self.inner.borrow().output.len()
    }

    pub fn output_ptr(&self) -> *const u8 {
        let inner = self.inner.borrow();
        if inner.output.is_empty() {
            std::ptr::null()
        } else {
            inner.output.as_ptr()
        }
    }

    pub fn consume_output(&self, n: usize) {
        let mut inner = self.inner.borrow_mut();
        let n = cmp::min(n, inner.output.len());
        inner.output.drain(..n);
    }
}

impl Read for BufferedIo {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        mut buf: ReadBufCursor<'_>,
    ) -> Poll<Result<(), io::Error>> {
        let mut inner = self.inner.borrow_mut();
        if inner.input.is_empty() {
            if inner.read_closed {
                return Poll::Ready(Ok(()));
            }

            inner.read_waker = Some(cx.waker().clone());
            return Poll::Pending;
        }

        let len = cmp::min(buf.remaining(), inner.input.len());
        let (front, back) = inner.input.as_slices();
        let front_len = cmp::min(len, front.len());
        buf.put_slice(&front[..front_len]);

        if len > front_len {
            buf.put_slice(&back[..len - front_len]);
        }

        inner.input.drain(..len);
        Poll::Ready(Ok(()))
    }
}

impl Write for BufferedIo {
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<Result<usize, io::Error>> {
        self.inner.borrow_mut().output.extend_from_slice(buf);
        Poll::Ready(Ok(buf.len()))
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Result<(), io::Error>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Result<(), io::Error>> {
        Poll::Ready(Ok(()))
    }
}

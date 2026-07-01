use std::task::{RawWaker, RawWakerVTable, Waker};

pub fn noop_waker() -> Waker {
    unsafe { Waker::from_raw(raw_waker()) }
}

fn raw_waker() -> RawWaker {
    RawWaker::new(std::ptr::null(), &VTABLE)
}

static VTABLE: RawWakerVTable = RawWakerVTable::new(clone, wake, wake_by_ref, drop_waker);

unsafe fn clone(_: *const ()) -> RawWaker {
    raw_waker()
}

unsafe fn wake(_: *const ()) {}

unsafe fn wake_by_ref(_: *const ()) {}

unsafe fn drop_waker(_: *const ()) {}

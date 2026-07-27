//! Stable native media-core ABI.
//!
//! The byte source is authoritative only for native incremental decoding; the
//! Dart artifact remains the durable byte authority. Cursor and frame handles
//! use shared ownership so releasing a source handle cannot invalidate an
//! already-created cursor, while epoch checks still reject stale work.

use std::ptr;
use std::slice;
use std::sync::{Arc, RwLock};

pub const ABI_VERSION: u32 = 3;
pub const LIB_VERSION: u32 = 0x000B_0000;

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Status {
    Ok = 0,
    Null = 1,
    StaleEpoch = 2,
    InvalidOffset = 3,
    Sealed = 4,
    Budget = 5,
    Failed = 6,
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CursorStatus {
    Ok = 0,
    Null = 1,
    StaleEpoch = 2,
    NeedMoreData = 3,
    End = 4,
    Unsupported = 5,
    Failed = 6,
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContainerKind {
    Unknown = 0,
    Webp = 1,
    Gif = 2,
    Other = 3,
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PixelFormat {
    Rgba8888 = 0,
}

struct SourceState {
    epoch: u64,
    max_bytes: usize,
    bytes: Vec<u8>,
    sealed: bool,
}

impl SourceState {
    fn new(epoch: u64, max_bytes: usize) -> Self {
        Self {
            epoch,
            max_bytes,
            bytes: Vec::new(),
            sealed: false,
        }
    }

    fn append(&mut self, epoch: u64, offset: usize, bytes: &[u8]) -> Status {
        if epoch != self.epoch {
            return Status::StaleEpoch;
        }
        if self.sealed {
            return Status::Sealed;
        }
        if offset != self.bytes.len() {
            return Status::InvalidOffset;
        }
        let Some(next_len) = self.bytes.len().checked_add(bytes.len()) else {
            return Status::Budget;
        };
        if next_len > self.max_bytes {
            return Status::Budget;
        }
        self.bytes.extend_from_slice(bytes);
        Status::Ok
    }

    fn sniff(&self) -> ContainerKind {
        sniff(&self.bytes, self.sealed)
    }
}

pub struct ByteSource {
    inner: Arc<RwLock<SourceState>>,
}

impl ByteSource {
    fn new(epoch: u64, max_bytes: usize) -> Self {
        Self {
            inner: Arc::new(RwLock::new(SourceState::new(epoch, max_bytes))),
        }
    }
}

pub struct Cursor {
    source: Arc<RwLock<SourceState>>,
    epoch: u64,
    target_width: u32,
    target_height: u32,
    next_index: u32,
}

#[derive(Debug)]
struct FrameData {
    epoch: u64,
    index: u32,
    width: u32,
    height: u32,
    duration_us: u64,
    format: PixelFormat,
    bytes: Vec<u8>,
}

pub struct FrameHandle {
    data: Arc<FrameData>,
}

impl FrameHandle {
    #[cfg(test)]
    fn test_frame(epoch: u64, index: u32, bytes: Vec<u8>) -> Self {
        Self {
            data: Arc::new(FrameData {
                epoch,
                index,
                width: 1,
                height: 1,
                duration_us: 16_000,
                format: PixelFormat::Rgba8888,
                bytes,
            }),
        }
    }
}

fn sniff(bytes: &[u8], sealed: bool) -> ContainerKind {
    if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return ContainerKind::Webp;
    }
    if bytes.len() >= 6 && (&bytes[..6] == b"GIF87a" || &bytes[..6] == b"GIF89a") {
        return ContainerKind::Gif;
    }
    if sealed {
        ContainerKind::Other
    } else {
        ContainerKind::Unknown
    }
}

#[no_mangle]
pub extern "C" fn zic_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn zic_version() -> u32 {
    LIB_VERSION
}

#[no_mangle]
pub extern "C" fn zic_source_create(epoch: u64, max_bytes: usize) -> *mut ByteSource {
    Box::into_raw(Box::new(ByteSource::new(epoch, max_bytes)))
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_free(source: *mut ByteSource) {
    if !source.is_null() {
        drop(Box::from_raw(source));
    }
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_append(
    source: *mut ByteSource,
    epoch: u64,
    offset: usize,
    data: *const u8,
    len: usize,
) -> u32 {
    let Some(source) = source.as_ref() else {
        return Status::Null as u32;
    };
    if len > 0 && data.is_null() {
        return Status::Null as u32;
    }
    let bytes = if len == 0 {
        &[]
    } else {
        slice::from_raw_parts(data, len)
    };
    source
        .inner
        .write()
        .map_or(Status::Failed, |mut state| state.append(epoch, offset, bytes)) as u32
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_seal(source: *mut ByteSource, epoch: u64) -> u32 {
    let Some(source) = source.as_ref() else {
        return Status::Null as u32;
    };
    source.inner.write().map_or(Status::Failed, |mut state| {
        if epoch != state.epoch {
            return Status::StaleEpoch;
        }
        state.sealed = true;
        Status::Ok
    }) as u32
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_reset(source: *mut ByteSource, epoch: u64) -> u32 {
    let Some(source) = source.as_ref() else {
        return Status::Null as u32;
    };
    source.inner.write().map_or(Status::Failed, |mut state| {
        state.epoch = epoch;
        state.bytes.clear();
        state.sealed = false;
        Status::Ok
    }) as u32
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_len(source: *const ByteSource) -> usize {
    let Some(source) = source.as_ref() else {
        return 0;
    };
    source.inner.read().map_or(0, |state| state.bytes.len())
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_epoch(source: *const ByteSource) -> u64 {
    let Some(source) = source.as_ref() else {
        return 0;
    };
    source.inner.read().map_or(0, |state| state.epoch)
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_is_sealed(source: *const ByteSource) -> u32 {
    let Some(source) = source.as_ref() else {
        return 0;
    };
    source
        .inner
        .read()
        .map_or(0, |state| if state.sealed { 1 } else { 0 })
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_kind(source: *const ByteSource) -> u32 {
    let Some(source) = source.as_ref() else {
        return ContainerKind::Unknown as u32;
    };
    source
        .inner
        .read()
        .map_or(ContainerKind::Unknown, |state| state.sniff()) as u32
}

#[no_mangle]
pub unsafe extern "C" fn zic_cursor_create(
    source: *const ByteSource,
    epoch: u64,
    target_width: u32,
    target_height: u32,
) -> *mut Cursor {
    let Some(source) = source.as_ref() else {
        return ptr::null_mut();
    };
    if target_width == 0 || target_height == 0 {
        return ptr::null_mut();
    }
    let matches_epoch = match source.inner.read() {
        Ok(state) => state.epoch == epoch,
        Err(_) => false,
    };
    if !matches_epoch {
        return ptr::null_mut();
    }
    Box::into_raw(Box::new(Cursor {
        source: Arc::clone(&source.inner),
        epoch,
        target_width,
        target_height,
        next_index: 0,
    }))
}

#[no_mangle]
pub unsafe extern "C" fn zic_cursor_free(cursor: *mut Cursor) {
    if !cursor.is_null() {
        drop(Box::from_raw(cursor));
    }
}

#[no_mangle]
pub unsafe extern "C" fn zic_cursor_epoch(cursor: *const Cursor) -> u64 {
    cursor.as_ref().map_or(0, |cursor| cursor.epoch)
}

#[no_mangle]
pub unsafe extern "C" fn zic_cursor_decode_next(
    cursor: *mut Cursor,
    epoch: u64,
    out_frame: *mut *mut FrameHandle,
) -> u32 {
    if out_frame.is_null() {
        return CursorStatus::Null as u32;
    }
    *out_frame = ptr::null_mut();
    let Some(cursor) = cursor.as_mut() else {
        return CursorStatus::Null as u32;
    };
    if epoch != cursor.epoch {
        return CursorStatus::StaleEpoch as u32;
    }
    let Ok(source) = cursor.source.read() else {
        return CursorStatus::Failed as u32;
    };
    if source.epoch != epoch {
        return CursorStatus::StaleEpoch as u32;
    }
    match source.sniff() {
        ContainerKind::Unknown => CursorStatus::NeedMoreData as u32,
        ContainerKind::Gif | ContainerKind::Other => CursorStatus::Unsupported as u32,
        ContainerKind::Webp if !source.sealed => CursorStatus::NeedMoreData as u32,
        ContainerKind::Webp => {
            // The stable ownership ABI is complete; the actual WebP decoder is
            // introduced in the next native iteration. Do not synthesize a
            // frame or consume cursor state before a real decoder exists.
            let _ = (cursor.target_width, cursor.target_height, cursor.next_index);
            CursorStatus::Unsupported as u32
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn zic_frame_retain(frame: *const FrameHandle) -> *mut FrameHandle {
    let Some(frame) = frame.as_ref() else {
        return ptr::null_mut();
    };
    Box::into_raw(Box::new(FrameHandle {
        data: Arc::clone(&frame.data),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn zic_frame_release(frame: *mut FrameHandle) {
    if !frame.is_null() {
        drop(Box::from_raw(frame));
    }
}

#[no_mangle]
pub unsafe extern "C" fn zic_frame_epoch(frame: *const FrameHandle) -> u64 {
    frame.as_ref().map_or(0, |frame| frame.data.epoch)
}

#[no_mangle]
pub unsafe extern "C" fn zic_frame_index(frame: *const FrameHandle) -> u32 {
    frame.as_ref().map_or(0, |frame| frame.data.index)
}

#[no_mangle]
pub unsafe extern "C" fn zic_frame_width(frame: *const FrameHandle) -> u32 {
    frame.as_ref().map_or(0, |frame| frame.data.width)
}

#[no_mangle]
pub unsafe extern "C" fn zic_frame_height(frame: *const FrameHandle) -> u32 {
    frame.as_ref().map_or(0, |frame| frame.data.height)
}

#[no_mangle]
pub unsafe extern "C" fn zic_frame_duration_us(frame: *const FrameHandle) -> u64 {
    frame.as_ref().map_or(0, |frame| frame.data.duration_us)
}

#[no_mangle]
pub unsafe extern "C" fn zic_frame_format(frame: *const FrameHandle) -> u32 {
    frame
        .as_ref()
        .map_or(PixelFormat::Rgba8888, |frame| frame.data.format) as u32
}

#[no_mangle]
pub unsafe extern "C" fn zic_frame_len(frame: *const FrameHandle) -> usize {
    frame.as_ref().map_or(0, |frame| frame.data.bytes.len())
}

#[no_mangle]
pub unsafe extern "C" fn zic_frame_data(frame: *const FrameHandle) -> *const u8 {
    frame.as_ref().map_or(ptr::null(), |frame| {
        if frame.data.bytes.is_empty() {
            ptr::null()
        } else {
            frame.data.bytes.as_ptr()
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exported_versions_are_stable() {
        assert_eq!(zic_abi_version(), 3);
        assert_eq!(zic_version(), 0x000B_0000);
    }

    #[test]
    fn source_requires_contiguous_offsets_and_matching_epoch() {
        let source = ByteSource::new(7, 32);
        let mut state = source.inner.write().unwrap();
        assert_eq!(state.append(7, 0, b"RIFF"), Status::Ok);
        assert_eq!(state.append(7, 5, b"x"), Status::InvalidOffset);
        assert_eq!(state.append(8, 4, b"x"), Status::StaleEpoch);
        assert_eq!(state.append(7, 4, b"....WEBP"), Status::Ok);
        assert_eq!(state.sniff(), ContainerKind::Webp);
    }

    #[test]
    fn source_enforces_budget_and_seal() {
        let source = ByteSource::new(1, 4);
        let mut state = source.inner.write().unwrap();
        assert_eq!(state.append(1, 0, b"1234"), Status::Ok);
        assert_eq!(state.append(1, 4, b"5"), Status::Budget);
        state.sealed = true;
        assert_eq!(state.append(1, 4, b""), Status::Sealed);
    }

    #[test]
    fn cursor_owns_source_state_and_rejects_reset_epoch() {
        let source = ByteSource::new(4, 32);
        let cursor = Cursor {
            source: Arc::clone(&source.inner),
            epoch: 4,
            target_width: 8,
            target_height: 8,
            next_index: 0,
        };
        drop(source);
        assert_eq!(cursor.source.read().unwrap().epoch, 4);
        cursor.source.write().unwrap().epoch = 5;
        assert_ne!(cursor.source.read().unwrap().epoch, cursor.epoch);
    }

    #[test]
    fn retained_frame_has_independent_handle_ownership() {
        let frame = Box::new(FrameHandle::test_frame(2, 3, vec![1, 2, 3, 4]));
        let ptr = Box::into_raw(frame);
        let retained = unsafe { zic_frame_retain(ptr) };
        assert!(!retained.is_null());
        unsafe { zic_frame_release(ptr) };
        assert_eq!(unsafe { zic_frame_epoch(retained) }, 2);
        assert_eq!(unsafe { zic_frame_index(retained) }, 3);
        assert_eq!(unsafe { zic_frame_len(retained) }, 4);
        unsafe { zic_frame_release(retained) };
    }

    #[test]
    fn sniff_is_safe_at_every_prefix_boundary() {
        let webp = b"RIFF....WEBPpayload";
        for end in 0..=webp.len() {
            let kind = sniff(&webp[..end], end == webp.len());
            if end >= 12 {
                assert_eq!(kind, ContainerKind::Webp);
            }
        }
        assert_eq!(sniff(b"GIF89a", false), ContainerKind::Gif);
        assert_eq!(sniff(b"jpeg", true), ContainerKind::Other);
    }
}

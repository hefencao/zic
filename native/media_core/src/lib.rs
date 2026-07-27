//! Stable native media-core ABI.
//!
//! This phase introduces the authoritative incremental byte source used by
//! future WebP cursors. Decoding is intentionally not exposed yet.

use std::slice;

pub const ABI_VERSION: u32 = 2;
pub const LIB_VERSION: u32 = 0x0007_0000;

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Status {
    Ok = 0,
    Null = 1,
    StaleEpoch = 2,
    InvalidOffset = 3,
    Sealed = 4,
    Budget = 5,
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContainerKind {
    Unknown = 0,
    Webp = 1,
    Gif = 2,
    Other = 3,
}

pub struct ByteSource {
    epoch: u64,
    max_bytes: usize,
    bytes: Vec<u8>,
    sealed: bool,
}

impl ByteSource {
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
    let Some(source) = source.as_mut() else {
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
    source.append(epoch, offset, bytes) as u32
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_seal(source: *mut ByteSource, epoch: u64) -> u32 {
    let Some(source) = source.as_mut() else {
        return Status::Null as u32;
    };
    if epoch != source.epoch {
        return Status::StaleEpoch as u32;
    }
    source.sealed = true;
    Status::Ok as u32
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_reset(
    source: *mut ByteSource,
    epoch: u64,
) -> u32 {
    let Some(source) = source.as_mut() else {
        return Status::Null as u32;
    };
    source.epoch = epoch;
    source.bytes.clear();
    source.sealed = false;
    Status::Ok as u32
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_len(source: *const ByteSource) -> usize {
    source.as_ref().map_or(0, |source| source.bytes.len())
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_epoch(source: *const ByteSource) -> u64 {
    source.as_ref().map_or(0, |source| source.epoch)
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_is_sealed(source: *const ByteSource) -> u32 {
    source
        .as_ref()
        .map_or(0, |source| if source.sealed { 1 } else { 0 })
}

#[no_mangle]
pub unsafe extern "C" fn zic_source_kind(source: *const ByteSource) -> u32 {
    source
        .as_ref()
        .map_or(ContainerKind::Unknown, ByteSource::sniff) as u32
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exported_versions_are_stable() {
        assert_eq!(zic_abi_version(), 2);
        assert_eq!(zic_version(), 0x0007_0000);
    }

    #[test]
    fn source_requires_contiguous_offsets_and_matching_epoch() {
        let mut source = ByteSource::new(7, 32);
        assert_eq!(source.append(7, 0, b"RIFF"), Status::Ok);
        assert_eq!(source.append(7, 5, b"x"), Status::InvalidOffset);
        assert_eq!(source.append(8, 4, b"x"), Status::StaleEpoch);
        assert_eq!(source.append(7, 4, b"....WEBP"), Status::Ok);
        assert_eq!(source.sniff(), ContainerKind::Webp);
    }

    #[test]
    fn source_enforces_budget_and_seal() {
        let mut source = ByteSource::new(1, 4);
        assert_eq!(source.append(1, 0, b"1234"), Status::Ok);
        assert_eq!(source.append(1, 4, b"5"), Status::Budget);
        source.sealed = true;
        assert_eq!(source.append(1, 4, b""), Status::Sealed);
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

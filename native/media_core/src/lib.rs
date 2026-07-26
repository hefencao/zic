//! Stable native ABI smoke surface for zic.
//!
//! Animated WebP source/cursor/frame APIs are introduced in Phase 4.

pub const ABI_VERSION: u32 = 1;
pub const LIB_VERSION: u32 = 0x0002_0000;

#[no_mangle]
pub extern "C" fn zic_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn zic_version() -> u32 {
    LIB_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exported_versions_are_stable() {
        assert_eq!(zic_abi_version(), 1);
        assert_eq!(zic_version(), 0x0002_0000);
    }
}

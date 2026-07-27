use crate::{FrameHandle, PixelFormat};

pub(crate) const BLIT_OK: i32 = 0;
pub(crate) const BLIT_NULL: i32 = 1;
pub(crate) const BLIT_INVALID_FRAME: i32 = 2;
pub(crate) const BLIT_SURFACE_FAILED: i32 = 3;
pub(crate) const BLIT_LOCK_FAILED: i32 = 4;

pub(crate) fn copy_premultiplied_rgba(
    source: &[u8],
    width: usize,
    height: usize,
    destination: &mut [u8],
    destination_stride_pixels: usize,
) -> bool {
    let Some(source_row_bytes) = width.checked_mul(4) else {
        return false;
    };
    let Some(required_source) = source_row_bytes.checked_mul(height) else {
        return false;
    };
    let Some(destination_row_bytes) = destination_stride_pixels.checked_mul(4) else {
        return false;
    };
    let Some(required_destination) = destination_row_bytes.checked_mul(height) else {
        return false;
    };
    if source.len() < required_source
        || destination.len() < required_destination
        || destination_stride_pixels < width
    {
        return false;
    }

    for row in 0..height {
        let source_start = row * source_row_bytes;
        let destination_start = row * destination_row_bytes;
        let source_row = &source[source_start..source_start + source_row_bytes];
        let destination_row =
            &mut destination[destination_start..destination_start + source_row_bytes];
        for (input, output) in source_row
            .chunks_exact(4)
            .zip(destination_row.chunks_exact_mut(4))
        {
            let alpha = input[3] as u16;
            output[0] = ((input[0] as u16 * alpha + 127) / 255) as u8;
            output[1] = ((input[1] as u16 * alpha + 127) / 255) as u8;
            output[2] = ((input[2] as u16 * alpha + 127) / 255) as u8;
            output[3] = input[3];
        }
    }
    true
}

#[cfg(target_os = "android")]
mod android {
    use super::*;
    use std::ffi::c_void;
    use std::slice;

    const WINDOW_FORMAT_RGBA_8888: i32 = 1;

    #[repr(C)]
    struct ANativeWindow;

    #[repr(C)]
    struct ANativeWindowBuffer {
        width: i32,
        height: i32,
        stride: i32,
        format: i32,
        bits: *mut c_void,
        reserved: [u32; 6],
    }

    extern "C" {
        fn ANativeWindow_fromSurface(env: *mut c_void, surface: *mut c_void)
            -> *mut ANativeWindow;
        fn ANativeWindow_release(window: *mut ANativeWindow);
        fn ANativeWindow_setBuffersGeometry(
            window: *mut ANativeWindow,
            width: i32,
            height: i32,
            format: i32,
        ) -> i32;
        fn ANativeWindow_lock(
            window: *mut ANativeWindow,
            buffer: *mut ANativeWindowBuffer,
            dirty_bounds: *mut c_void,
        ) -> i32;
        fn ANativeWindow_unlockAndPost(window: *mut ANativeWindow) -> i32;
    }

    struct WindowOwner(*mut ANativeWindow);

    impl Drop for WindowOwner {
        fn drop(&mut self) {
            unsafe { ANativeWindow_release(self.0) };
        }
    }

    #[no_mangle]
    pub unsafe extern "system" fn Java_dev_zic_texture_NativeBlitter_retain(
        _env: *mut c_void,
        _class: *mut c_void,
        frame_address: i64,
    ) -> i64 {
        if frame_address == 0 {
            return 0;
        }
        let frame = frame_address as usize as *const FrameHandle;
        crate::zic_frame_retain(frame) as usize as i64
    }

    #[no_mangle]
    pub unsafe extern "system" fn Java_dev_zic_texture_NativeBlitter_release(
        _env: *mut c_void,
        _class: *mut c_void,
        frame_address: i64,
    ) {
        if frame_address != 0 {
            crate::zic_frame_release(frame_address as usize as *mut FrameHandle);
        }
    }

    #[no_mangle]
    pub unsafe extern "system" fn Java_dev_zic_texture_NativeBlitter_blit(
        env: *mut c_void,
        _class: *mut c_void,
        surface: *mut c_void,
        frame_address: i64,
    ) -> i32 {
        if env.is_null() || surface.is_null() || frame_address == 0 {
            return BLIT_NULL;
        }
        let frame = (frame_address as usize as *const FrameHandle).as_ref();
        let Some(frame) = frame else {
            return BLIT_INVALID_FRAME;
        };
        if frame.data.format != PixelFormat::Rgba8888
            || frame.data.width == 0
            || frame.data.height == 0
        {
            return BLIT_INVALID_FRAME;
        }
        if frame.data.width > i32::MAX as u32 || frame.data.height > i32::MAX as u32 {
            return BLIT_INVALID_FRAME;
        }
        let width = frame.data.width as usize;
        let height = frame.data.height as usize;
        let Some(expected) = width.checked_mul(height).and_then(|value| value.checked_mul(4))
        else {
            return BLIT_INVALID_FRAME;
        };
        if frame.data.bytes.len() < expected {
            return BLIT_INVALID_FRAME;
        }

        let window = ANativeWindow_fromSurface(env, surface);
        if window.is_null() {
            return BLIT_SURFACE_FAILED;
        }
        let window = WindowOwner(window);
        if ANativeWindow_setBuffersGeometry(
            window.0,
            frame.data.width as i32,
            frame.data.height as i32,
            WINDOW_FORMAT_RGBA_8888,
        ) != 0
        {
            return BLIT_SURFACE_FAILED;
        }

        let mut buffer = ANativeWindowBuffer {
            width: 0,
            height: 0,
            stride: 0,
            format: 0,
            bits: std::ptr::null_mut(),
            reserved: [0; 6],
        };
        if ANativeWindow_lock(window.0, &mut buffer, std::ptr::null_mut()) != 0 {
            return BLIT_LOCK_FAILED;
        }
        if buffer.bits.is_null()
            || buffer.stride <= 0
            || buffer.height <= 0
            || buffer.width < frame.data.width as i32
            || buffer.height < frame.data.height as i32
        {
            ANativeWindow_unlockAndPost(window.0);
            return BLIT_LOCK_FAILED;
        }
        let Some(destination_len) = (buffer.stride as usize)
            .checked_mul(buffer.height as usize)
            .and_then(|value| value.checked_mul(4))
        else {
            ANativeWindow_unlockAndPost(window.0);
            return BLIT_LOCK_FAILED;
        };
        let destination = slice::from_raw_parts_mut(buffer.bits.cast::<u8>(), destination_len);
        let copied = copy_premultiplied_rgba(
            &frame.data.bytes,
            width,
            height,
            destination,
            buffer.stride as usize,
        );
        let posted = ANativeWindow_unlockAndPost(window.0) == 0;
        if copied && posted {
            BLIT_OK
        } else {
            BLIT_LOCK_FAILED
        }
    }
}

#[cfg(test)]
mod tests {
    use super::copy_premultiplied_rgba;

    #[test]
    fn blit_copy_premultiplies_and_respects_destination_stride() {
        let source = [255, 64, 0, 128, 10, 20, 30, 255];
        let mut destination = [7u8; 16];

        assert!(copy_premultiplied_rgba(
            &source,
            2,
            1,
            &mut destination,
            4,
        ));
        assert_eq!(&destination[..8], &[128, 32, 0, 128, 10, 20, 30, 255]);
        assert_eq!(&destination[8..], &[7; 8]);
    }

    #[test]
    fn blit_copy_rejects_short_buffers() {
        assert!(!copy_premultiplied_rgba(&[0; 3], 1, 1, &mut [0; 4], 1));
        assert!(!copy_premultiplied_rgba(&[0; 4], 1, 1, &mut [0; 3], 1));
    }
}

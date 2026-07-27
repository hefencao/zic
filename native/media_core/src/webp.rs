use std::os::raw::{c_int, c_void};
use std::ptr;

const WEBP_DEMUX_ABI_VERSION: c_int = 0x0107;
const WEBP_DEMUX_PARSE_ERROR: c_int = -1;
const WEBP_DEMUX_PARSING_HEADER: c_int = 0;
const WEBP_DEMUX_DONE: c_int = 2;

const WEBP_FF_CANVAS_WIDTH: c_int = 1;
const WEBP_FF_CANVAS_HEIGHT: c_int = 2;
const WEBP_FF_BACKGROUND_COLOR: c_int = 4;

const WEBP_MUX_DISPOSE_BACKGROUND: c_int = 1;
const WEBP_MUX_NO_BLEND: c_int = 1;

const BYTES_PER_PIXEL: usize = 4;
const MAX_WORKING_BYTES: usize = 512 * 1024 * 1024;

#[repr(C)]
struct WebPData {
    bytes: *const u8,
    size: usize,
}

#[repr(C)]
struct WebPDemuxer {
    _private: [u8; 0],
}

#[repr(C)]
struct WebPIterator {
    frame_num: c_int,
    num_frames: c_int,
    x_offset: c_int,
    y_offset: c_int,
    width: c_int,
    height: c_int,
    duration: c_int,
    dispose_method: c_int,
    complete: c_int,
    fragment: WebPData,
    has_alpha: c_int,
    blend_method: c_int,
    pad: [u32; 2],
    private_: *mut c_void,
}

extern "C" {
    fn WebPDemuxInternal(
        data: *const WebPData,
        allow_partial: c_int,
        state: *mut c_int,
        version: c_int,
    ) -> *mut WebPDemuxer;
    fn WebPDemuxDelete(demux: *mut WebPDemuxer);
    fn WebPDemuxGetI(demux: *const WebPDemuxer, feature: c_int) -> u32;
    fn WebPDemuxGetFrame(
        demux: *const WebPDemuxer,
        frame_number: c_int,
        iter: *mut WebPIterator,
    ) -> c_int;
    fn WebPDemuxReleaseIterator(iter: *mut WebPIterator);

    fn WebPDecodeRGBAInto(
        data: *const u8,
        data_size: usize,
        output_buffer: *mut u8,
        output_buffer_size: usize,
        output_stride: c_int,
    ) -> *mut u8;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DecodeError {
    NeedMoreData,
    End,
    Failed,
}

#[derive(Debug)]
pub(crate) struct DecodedFrame {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) duration_us: u64,
    pub(crate) bytes: Vec<u8>,
}

#[derive(Clone, Copy, Debug)]
struct Rect {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
}

#[derive(Clone, Copy, Debug)]
struct PreviousFrame {
    rect: Rect,
    dispose_background: bool,
}

pub(crate) struct Decoder {
    target_width: usize,
    target_height: usize,
    source_width: usize,
    source_height: usize,
    background: [u8; 4],
    canvas: Vec<u8>,
    previous: Option<PreviousFrame>,
    next_frame_number: c_int,
    initialized: bool,
}

impl Decoder {
    pub(crate) fn new(target_width: u32, target_height: u32) -> Self {
        Self {
            target_width: target_width as usize,
            target_height: target_height as usize,
            source_width: 0,
            source_height: 0,
            background: [0; 4],
            canvas: Vec::new(),
            previous: None,
            next_frame_number: 1,
            initialized: false,
        }
    }

    pub(crate) fn decode_next(
        &mut self,
        bytes: &[u8],
        sealed: bool,
    ) -> Result<DecodedFrame, DecodeError> {
        if bytes.len() < 12 {
            return Err(if sealed {
                DecodeError::Failed
            } else {
                DecodeError::NeedMoreData
            });
        }

        let data = WebPData {
            bytes: bytes.as_ptr(),
            size: bytes.len(),
        };
        let mut demux_state = WEBP_DEMUX_PARSING_HEADER;
        let demux_ptr = unsafe {
            WebPDemuxInternal(
                &data,
                1,
                &mut demux_state,
                WEBP_DEMUX_ABI_VERSION,
            )
        };
        if demux_ptr.is_null() {
            return Err(if !sealed && demux_state != WEBP_DEMUX_PARSE_ERROR {
                DecodeError::NeedMoreData
            } else {
                DecodeError::Failed
            });
        }
        let demux = Demux(demux_ptr);

        let source_width = unsafe { WebPDemuxGetI(demux.0, WEBP_FF_CANVAS_WIDTH) } as usize;
        let source_height = unsafe { WebPDemuxGetI(demux.0, WEBP_FF_CANVAS_HEIGHT) } as usize;
        if source_width == 0 || source_height == 0 {
            return Err(if sealed {
                DecodeError::Failed
            } else {
                DecodeError::NeedMoreData
            });
        }
        self.ensure_canvas(demux.0, source_width, source_height)?;

        let mut raw_iter = unsafe { std::mem::zeroed::<WebPIterator>() };
        let found = unsafe {
            WebPDemuxGetFrame(demux.0, self.next_frame_number, &mut raw_iter)
        } != 0;
        if !found {
            return Err(if sealed || demux_state == WEBP_DEMUX_DONE {
                DecodeError::End
            } else {
                DecodeError::NeedMoreData
            });
        }
        let iter = Iter(raw_iter);
        if iter.0.complete == 0 {
            return Err(if sealed {
                DecodeError::Failed
            } else {
                DecodeError::NeedMoreData
            });
        }
        if iter.0.width <= 0
            || iter.0.height <= 0
            || iter.0.x_offset < 0
            || iter.0.y_offset < 0
        {
            return Err(DecodeError::Failed);
        }

        let source_rect = Rect {
            x: iter.0.x_offset as usize,
            y: iter.0.y_offset as usize,
            width: iter.0.width as usize,
            height: iter.0.height as usize,
        };
        if source_rect.x.saturating_add(source_rect.width) > source_width
            || source_rect.y.saturating_add(source_rect.height) > source_height
        {
            return Err(DecodeError::Failed);
        }
        let target_rect = scale_rect(
            source_rect,
            source_width,
            source_height,
            self.target_width,
            self.target_height,
        )?;

        let fragment_len = rgba_len(source_rect.width, source_rect.height)?;
        if fragment_len > MAX_WORKING_BYTES
            || iter.0.fragment.bytes.is_null()
            || iter.0.fragment.size == 0
            || source_rect.width > c_int::MAX as usize / BYTES_PER_PIXEL
        {
            return Err(DecodeError::Failed);
        }
        let mut fragment = vec![0u8; fragment_len];
        let decoded = unsafe {
            WebPDecodeRGBAInto(
                iter.0.fragment.bytes,
                iter.0.fragment.size,
                fragment.as_mut_ptr(),
                fragment.len(),
                (source_rect.width * BYTES_PER_PIXEL) as c_int,
            )
        };
        if decoded.is_null() {
            return Err(DecodeError::Failed);
        }

        let scaled = scale_rgba(
            &fragment,
            source_rect.width,
            source_rect.height,
            target_rect.width,
            target_rect.height,
        )?;
        let mut next_canvas = self.canvas.clone();
        if let Some(previous) = self.previous {
            if previous.dispose_background {
                fill_rect(
                    &mut next_canvas,
                    self.target_width,
                    self.target_height,
                    previous.rect,
                    self.background,
                );
            }
        }
        composite(
            &mut next_canvas,
            self.target_width,
            self.target_height,
            target_rect,
            &scaled,
            iter.0.blend_method != WEBP_MUX_NO_BLEND,
        )?;

        let duration_ms = iter.0.duration.max(0) as u64;
        let duration_us = duration_ms.saturating_mul(1_000);
        self.canvas = next_canvas;
        self.previous = Some(PreviousFrame {
            rect: target_rect,
            dispose_background: iter.0.dispose_method == WEBP_MUX_DISPOSE_BACKGROUND,
        });
        self.next_frame_number = self.next_frame_number.saturating_add(1);

        Ok(DecodedFrame {
            width: self.target_width as u32,
            height: self.target_height as u32,
            duration_us,
            bytes: self.canvas.clone(),
        })
    }

    fn ensure_canvas(
        &mut self,
        demux: *const WebPDemuxer,
        source_width: usize,
        source_height: usize,
    ) -> Result<(), DecodeError> {
        if self.initialized {
            if source_width != self.source_width || source_height != self.source_height {
                return Err(DecodeError::Failed);
            }
            return Ok(());
        }
        let canvas_len = rgba_len(self.target_width, self.target_height)?;
        if canvas_len > MAX_WORKING_BYTES {
            return Err(DecodeError::Failed);
        }
        let background = unsafe { WebPDemuxGetI(demux, WEBP_FF_BACKGROUND_COLOR) };
        self.background = [
            ((background >> 16) & 0xff) as u8,
            ((background >> 8) & 0xff) as u8,
            (background & 0xff) as u8,
            ((background >> 24) & 0xff) as u8,
        ];
        self.canvas = vec![0u8; canvas_len];
        fill_rect(
            &mut self.canvas,
            self.target_width,
            self.target_height,
            Rect {
                x: 0,
                y: 0,
                width: self.target_width,
                height: self.target_height,
            },
            self.background,
        );
        self.source_width = source_width;
        self.source_height = source_height;
        self.initialized = true;
        Ok(())
    }
}

struct Demux(*mut WebPDemuxer);

impl Drop for Demux {
    fn drop(&mut self) {
        unsafe { WebPDemuxDelete(self.0) }
    }
}

struct Iter(WebPIterator);

impl Drop for Iter {
    fn drop(&mut self) {
        unsafe { WebPDemuxReleaseIterator(&mut self.0) }
    }
}

fn rgba_len(width: usize, height: usize) -> Result<usize, DecodeError> {
    width
        .checked_mul(height)
        .and_then(|pixels| pixels.checked_mul(BYTES_PER_PIXEL))
        .ok_or(DecodeError::Failed)
}

fn scale_rect(
    rect: Rect,
    source_width: usize,
    source_height: usize,
    target_width: usize,
    target_height: usize,
) -> Result<Rect, DecodeError> {
    let x0 = rect.x.saturating_mul(target_width) / source_width;
    let y0 = rect.y.saturating_mul(target_height) / source_height;
    let x1 = rect
        .x
        .saturating_add(rect.width)
        .saturating_mul(target_width)
        .saturating_add(source_width - 1)
        / source_width;
    let y1 = rect
        .y
        .saturating_add(rect.height)
        .saturating_mul(target_height)
        .saturating_add(source_height - 1)
        / source_height;
    let x1 = x1.min(target_width);
    let y1 = y1.min(target_height);
    if x0 >= x1 || y0 >= y1 {
        return Err(DecodeError::Failed);
    }
    Ok(Rect {
        x: x0,
        y: y0,
        width: x1 - x0,
        height: y1 - y0,
    })
}

fn scale_rgba(
    source: &[u8],
    source_width: usize,
    source_height: usize,
    target_width: usize,
    target_height: usize,
) -> Result<Vec<u8>, DecodeError> {
    let target_len = rgba_len(target_width, target_height)?;
    if source.len() != rgba_len(source_width, source_height)?
        || target_len > MAX_WORKING_BYTES
    {
        return Err(DecodeError::Failed);
    }
    if source_width == target_width && source_height == target_height {
        return Ok(source.to_vec());
    }

    let mut target = vec![0u8; target_len];
    for target_y in 0..target_height {
        let source_y = ((target_y as f64 + 0.5) * source_height as f64
            / target_height as f64
            - 0.5)
            .clamp(0.0, (source_height - 1) as f64);
        let y0 = source_y.floor() as usize;
        let y1 = (y0 + 1).min(source_height - 1);
        let fy = source_y - y0 as f64;
        for target_x in 0..target_width {
            let source_x = ((target_x as f64 + 0.5) * source_width as f64
                / target_width as f64
                - 0.5)
                .clamp(0.0, (source_width - 1) as f64);
            let x0 = source_x.floor() as usize;
            let x1 = (x0 + 1).min(source_width - 1);
            let fx = source_x - x0 as f64;
            let samples = [
                (pixel(source, source_width, x0, y0), (1.0 - fx) * (1.0 - fy)),
                (pixel(source, source_width, x1, y0), fx * (1.0 - fy)),
                (pixel(source, source_width, x0, y1), (1.0 - fx) * fy),
                (pixel(source, source_width, x1, y1), fx * fy),
            ];
            let mut alpha = 0.0;
            let mut premultiplied = [0.0; 3];
            for (sample, weight) in samples {
                let sample_alpha = sample[3] as f64;
                alpha += sample_alpha * weight;
                for channel in 0..3 {
                    premultiplied[channel] +=
                        sample[channel] as f64 * sample_alpha * weight;
                }
            }
            let offset = (target_y * target_width + target_x) * BYTES_PER_PIXEL;
            target[offset + 3] = alpha.round().clamp(0.0, 255.0) as u8;
            if alpha > 0.0 {
                for channel in 0..3 {
                    target[offset + channel] =
                        (premultiplied[channel] / alpha).round().clamp(0.0, 255.0)
                            as u8;
                }
            }
        }
    }
    Ok(target)
}

fn pixel(source: &[u8], width: usize, x: usize, y: usize) -> [u8; 4] {
    let offset = (y * width + x) * BYTES_PER_PIXEL;
    [
        source[offset],
        source[offset + 1],
        source[offset + 2],
        source[offset + 3],
    ]
}

fn fill_rect(
    canvas: &mut [u8],
    canvas_width: usize,
    canvas_height: usize,
    rect: Rect,
    color: [u8; 4],
) {
    let max_x = rect.x.saturating_add(rect.width).min(canvas_width);
    let max_y = rect.y.saturating_add(rect.height).min(canvas_height);
    for y in rect.y.min(canvas_height)..max_y {
        for x in rect.x.min(canvas_width)..max_x {
            let offset = (y * canvas_width + x) * BYTES_PER_PIXEL;
            canvas[offset..offset + BYTES_PER_PIXEL].copy_from_slice(&color);
        }
    }
}

fn composite(
    canvas: &mut [u8],
    canvas_width: usize,
    canvas_height: usize,
    rect: Rect,
    frame: &[u8],
    blend: bool,
) -> Result<(), DecodeError> {
    if frame.len() != rgba_len(rect.width, rect.height)?
        || rect.x.saturating_add(rect.width) > canvas_width
        || rect.y.saturating_add(rect.height) > canvas_height
    {
        return Err(DecodeError::Failed);
    }
    for y in 0..rect.height {
        for x in 0..rect.width {
            let source_offset = (y * rect.width + x) * BYTES_PER_PIXEL;
            let target_offset =
                ((rect.y + y) * canvas_width + rect.x + x) * BYTES_PER_PIXEL;
            let source = &frame[source_offset..source_offset + BYTES_PER_PIXEL];
            let target = &mut canvas[target_offset..target_offset + BYTES_PER_PIXEL];
            if blend {
                blend_source_over(target, source);
            } else {
                target.copy_from_slice(source);
            }
        }
    }
    Ok(())
}

fn blend_source_over(target: &mut [u8], source: &[u8]) {
    let source_alpha = source[3] as u32;
    if source_alpha == 0 {
        return;
    }
    if source_alpha == 255 {
        target.copy_from_slice(source);
        return;
    }
    let target_alpha = target[3] as u32;
    let inverse = 255 - source_alpha;
    let output_alpha = source_alpha + (target_alpha * inverse + 127) / 255;
    if output_alpha == 0 {
        target.fill(0);
        return;
    }
    for channel in 0..3 {
        let numerator = source[channel] as u64 * source_alpha as u64 * 255
            + target[channel] as u64 * target_alpha as u64 * inverse as u64;
        let denominator = output_alpha as u64 * 255;
        target[channel] = ((numerator + denominator / 2) / denominator).min(255) as u8;
    }
    target[3] = output_alpha.min(255) as u8;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_over_blends_straight_alpha() {
        let mut target = [0, 0, 255, 255];
        blend_source_over(&mut target, &[255, 0, 0, 128]);
        assert!((target[0] as i32 - 128).abs() <= 1);
        assert_eq!(target[1], 0);
        assert!((target[2] as i32 - 127).abs() <= 1);
        assert_eq!(target[3], 255);
    }

    #[test]
    fn scale_rect_preserves_outer_edges() {
        let rect = scale_rect(
            Rect {
                x: 1,
                y: 1,
                width: 2,
                height: 2,
            },
            4,
            4,
            8,
            8,
        )
        .unwrap();
        assert_eq!(rect.x, 2);
        assert_eq!(rect.y, 2);
        assert_eq!(rect.width, 4);
        assert_eq!(rect.height, 4);
    }
}

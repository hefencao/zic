use std::os::raw::{c_int, c_void};
use std::ptr;

const WEBP_DEMUX_ABI_VERSION: c_int = 0x0107;
const WEBP_DEMUX_PARSING_HEADER: c_int = 0;
const WEBP_DEMUX_DONE: c_int = 2;

const WEBP_FF_CANVAS_WIDTH: c_int = 1;
const WEBP_FF_CANVAS_HEIGHT: c_int = 2;
const WEBP_FF_LOOP_COUNT: c_int = 3;
const WEBP_FF_BACKGROUND_COLOR: c_int = 4;
const WEBP_FF_FRAME_COUNT: c_int = 5;

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
    fn WebPGetDecoderVersion() -> c_int;
    fn WebPGetDemuxVersion() -> c_int;
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

pub(crate) fn decoder_version() -> u32 {
    unsafe { WebPGetDecoderVersion() as u32 }
}

pub(crate) fn demux_version() -> u32 {
    unsafe { WebPGetDemuxVersion() as u32 }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DecodeError {
    NeedMoreData,
    End,
    Failed,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct AnimationMeta {
    pub(crate) frame_count: u32,
    pub(crate) loop_count: u32,
    pub(crate) complete: bool,
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
    max_width: usize,
    max_height: usize,
    target_width: usize,
    target_height: usize,
    source_width: usize,
    source_height: usize,
    background: [u8; 4],
    canvas: Vec<u8>,
    previous: Option<PreviousFrame>,
    next_frame_number: c_int,
    initialized: bool,
    meta: AnimationMeta,
    ended: bool,
}

impl Decoder {
    pub(crate) fn new(target_width: u32, target_height: u32) -> Self {
        Self {
            max_width: target_width as usize,
            max_height: target_height as usize,
            target_width: 0,
            target_height: 0,
            source_width: 0,
            source_height: 0,
            background: [0; 4],
            canvas: Vec::new(),
            previous: None,
            next_frame_number: 1,
            initialized: false,
            meta: AnimationMeta::default(),
            ended: false,
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
        let demux_ptr =
            unsafe { WebPDemuxInternal(&data, 1, &mut demux_state, WEBP_DEMUX_ABI_VERSION) };
        if demux_ptr.is_null() {
            // libwebp may report a parse error for a valid, still-incomplete
            // RIFF/WebP prefix. Until the source is sealed, the caller must
            // be able to append more bytes rather than treating it as a
            // terminal decoder failure.
            return Err(if sealed {
                DecodeError::Failed
            } else {
                DecodeError::NeedMoreData
            });
        }
        let demux = Demux(demux_ptr);
        self.meta = AnimationMeta {
            frame_count: unsafe { WebPDemuxGetI(demux.0, WEBP_FF_FRAME_COUNT) },
            loop_count: unsafe { WebPDemuxGetI(demux.0, WEBP_FF_LOOP_COUNT) },
            complete: demux_state == WEBP_DEMUX_DONE,
        };

        let source_width = unsafe { WebPDemuxGetI(demux.0, WEBP_FF_CANVAS_WIDTH) } as usize;
        let source_height = unsafe { WebPDemuxGetI(demux.0, WEBP_FF_CANVAS_HEIGHT) } as usize;
        if source_width == 0 || source_height == 0 {
            return Err(if sealed {
                DecodeError::Failed
            } else {
                DecodeError::NeedMoreData
            });
        }
        let mut raw_iter = unsafe { std::mem::zeroed::<WebPIterator>() };
        let found =
            unsafe { WebPDemuxGetFrame(demux.0, self.next_frame_number, &mut raw_iter) } != 0;
        if !found {
            if sealed || demux_state == WEBP_DEMUX_DONE {
                self.ended = true;
                return Err(DecodeError::End);
            }
            return Err(DecodeError::NeedMoreData);
        }
        let iter = Iter(raw_iter);
        if iter.0.complete == 0 {
            return Err(if sealed {
                DecodeError::Failed
            } else {
                DecodeError::NeedMoreData
            });
        }
        if iter.0.width <= 0 || iter.0.height <= 0 || iter.0.x_offset < 0 || iter.0.y_offset < 0 {
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
        // Partial demux metadata can report provisional canvas dimensions.
        // Wait until a complete frame is available before committing decoder
        // state, so later bytes can refine the container header safely.
        self.ensure_canvas(demux.0, source_width, source_height)?;
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

        // WebP blend and disposal semantics belong to the source pixel grid.
        // Scaling each animation sub-rectangle independently creates rounding
        // seams and horizontal strip displacement. Composite the authoritative
        // source canvas first, then scale the complete frame once.
        let mut next_canvas = self.canvas.clone();
        if let Some(previous) = self.previous {
            if previous.dispose_background {
                fill_rect(
                    &mut next_canvas,
                    self.source_width,
                    self.source_height,
                    previous.rect,
                    self.background,
                );
            }
        }
        composite(
            &mut next_canvas,
            self.source_width,
            self.source_height,
            source_rect,
            &fragment,
            iter.0.blend_method != WEBP_MUX_NO_BLEND,
        )?;

        let duration_ms = iter.0.duration.max(0) as u64;
        let duration_us = duration_ms.saturating_mul(1_000);
        self.canvas = next_canvas;
        self.previous = Some(PreviousFrame {
            rect: source_rect,
            dispose_background: iter.0.dispose_method == WEBP_MUX_DISPOSE_BACKGROUND,
        });
        self.next_frame_number = self.next_frame_number.saturating_add(1);
        self.ended = false;

        let output = scale_rgba(
            &self.canvas,
            self.source_width,
            self.source_height,
            self.target_width,
            self.target_height,
        )?;
        Ok(DecodedFrame {
            width: self.target_width as u32,
            height: self.target_height as u32,
            duration_us,
            bytes: output,
        })
    }

    pub(crate) fn metadata(&self) -> AnimationMeta {
        self.meta
    }

    pub(crate) fn ended(&self) -> bool {
        self.ended
    }

    pub(crate) fn rewind(&mut self) {
        self.target_width = 0;
        self.target_height = 0;
        self.source_width = 0;
        self.source_height = 0;
        self.background = [0; 4];
        self.canvas.clear();
        self.previous = None;
        self.next_frame_number = 1;
        self.initialized = false;
        self.ended = false;
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
        let (target_width, target_height) = fit_dimensions(
            source_width,
            source_height,
            self.max_width,
            self.max_height,
        )?;
        self.target_width = target_width;
        self.target_height = target_height;
        let canvas_len = rgba_len(source_width, source_height)?;
        let target_len = rgba_len(self.target_width, self.target_height)?;
        if canvas_len > MAX_WORKING_BYTES ||
            target_len > MAX_WORKING_BYTES ||
            canvas_len.saturating_add(target_len) > MAX_WORKING_BYTES
        {
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
            source_width,
            source_height,
            Rect {
                x: 0,
                y: 0,
                width: source_width,
                height: source_height,
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

fn fit_dimensions(
    source_width: usize,
    source_height: usize,
    max_width: usize,
    max_height: usize,
) -> Result<(usize, usize), DecodeError> {
    if source_width == 0 || source_height == 0 || max_width == 0 || max_height == 0 {
        return Err(DecodeError::Failed);
    }
    const ALIGNMENT: usize = 8;
    let width_bound = align_down(source_width.min(max_width), ALIGNMENT);
    let height_bound = align_down(source_height.min(max_height), ALIGNMENT);
    let width_limited = (width_bound as u128) * (source_height as u128)
        <= (height_bound as u128) * (source_width as u128);
    let ideal_width = if width_limited {
        width_bound
    } else {
        ((source_width as u128) * (height_bound as u128) / (source_height as u128))
            .max(ALIGNMENT as u128) as usize
    };
    let ideal_height = if width_limited {
        ((source_height as u128) * (width_bound as u128) / (source_width as u128))
            .max(ALIGNMENT as u128) as usize
    } else {
        height_bound
    };
    let largest_width = align_down(width_bound.min(ideal_width), ALIGNMENT);
    let largest_height = align_down(height_bound.min(ideal_height), ALIGNMENT);
    let minimum_area = (largest_width as u128) * (largest_height as u128) * 85 / 100;
    let mut best: Option<(usize, usize, u128, u128)> = None;

    let mut consider = |width: usize, height: usize| {
        if width < ALIGNMENT
            || height < ALIGNMENT
            || width > width_bound
            || height > height_bound
        {
            return;
        }
        let area = (width as u128) * (height as u128);
        if area < minimum_area {
            return;
        }
        let error = ((width as u128) * (source_height as u128))
            .abs_diff((height as u128) * (source_width as u128));
        let replace = best.map_or(true, |(_, current_height, current_error, current_area)| {
            let relative_error = error.saturating_mul(current_height as u128);
            let current_relative_error =
                current_error.saturating_mul(height as u128);
            relative_error < current_relative_error
                || (relative_error == current_relative_error && area > current_area)
        });
        if replace {
            best = Some((width, height, error, area));
        }
    };

    let mut width = largest_width;
    while width >= ALIGNMENT
        && (width as u128) * (largest_height as u128) >= minimum_area
    {
        let height = align_ratio_closest(
            (source_height as u128) * (width as u128),
            source_width as u128,
            height_bound,
            ALIGNMENT,
        );
        consider(width, height);
        if width == ALIGNMENT {
            break;
        }
        width -= ALIGNMENT;
    }

    let mut height = largest_height;
    while height >= ALIGNMENT
        && (largest_width as u128) * (height as u128) >= minimum_area
    {
        let width = align_ratio_closest(
            (source_width as u128) * (height as u128),
            source_height as u128,
            width_bound,
            ALIGNMENT,
        );
        consider(width, height);
        if height == ALIGNMENT {
            break;
        }
        height -= ALIGNMENT;
    }

    best.map(|(width, height, _, _)| (width, height))
        .ok_or(DecodeError::Failed)
}

fn align_ratio_closest(
    numerator: u128,
    denominator: u128,
    limit: usize,
    alignment: usize,
) -> usize {
    let floor = (numerator / denominator).min(usize::MAX as u128) as usize;
    let ceil = numerator
        .saturating_add(denominator.saturating_sub(1))
        / denominator;
    let down = align_down(floor, alignment);
    let up = align_up(
        ceil.min(usize::MAX as u128) as usize,
        alignment,
    )
    .min(limit);
    if down < alignment {
        return up;
    }
    let down_error = numerator.abs_diff((down as u128) * denominator);
    let up_error = numerator.abs_diff((up as u128) * denominator);
    if down_error <= up_error { down } else { up }
}

fn align_down(value: usize, alignment: usize) -> usize {
    let aligned = value / alignment * alignment;
    aligned.max(alignment)
}

fn align_up(value: usize, alignment: usize) -> usize {
    value
        .saturating_add(alignment.saturating_sub(1))
        / alignment
        * alignment
}

fn scale_rgba(
    source: &[u8],
    source_width: usize,
    source_height: usize,
    target_width: usize,
    target_height: usize,
) -> Result<Vec<u8>, DecodeError> {
    let target_len = rgba_len(target_width, target_height)?;
    if source.len() != rgba_len(source_width, source_height)? || target_len > MAX_WORKING_BYTES {
        return Err(DecodeError::Failed);
    }
    if source_width == target_width && source_height == target_height {
        return Ok(source.to_vec());
    }

    let mut target = vec![0u8; target_len];
    for target_y in 0..target_height {
        let source_y = ((target_y as f64 + 0.5) * source_height as f64 / target_height as f64
            - 0.5)
            .clamp(0.0, (source_height - 1) as f64);
        let y0 = source_y.floor() as usize;
        let y1 = (y0 + 1).min(source_height - 1);
        let fy = source_y - y0 as f64;
        for target_x in 0..target_width {
            let source_x = ((target_x as f64 + 0.5) * source_width as f64 / target_width as f64
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
                    premultiplied[channel] += sample[channel] as f64 * sample_alpha * weight;
                }
            }
            let offset = (target_y * target_width + target_x) * BYTES_PER_PIXEL;
            target[offset + 3] = alpha.round().clamp(0.0, 255.0) as u8;
            if alpha > 0.0 {
                for channel in 0..3 {
                    target[offset + channel] =
                        (premultiplied[channel] / alpha).round().clamp(0.0, 255.0) as u8;
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
            let target_offset = ((rect.y + y) * canvas_width + rect.x + x) * BYTES_PER_PIXEL;
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
    fn fit_dimensions_preserves_wide_and_tall_aspect_ratios() {
        assert_eq!(fit_dimensions(4000, 1000, 1000, 1000), Ok((992, 248)));
        assert_eq!(fit_dimensions(1000, 4000, 1000, 1000), Ok((248, 992)));
        assert_eq!(fit_dimensions(320, 640, 1080, 1920), Ok((320, 640)));
        assert_eq!(fit_dimensions(321, 643, 1080, 1920), Ok((320, 640)));
        assert_eq!(fit_dimensions(101, 99, 1080, 1920), Ok((96, 96)));
        let fitted = fit_dimensions(4032, 3024, 1080, 1920).unwrap();
        assert_eq!(fitted.0 % 8, 0);
        assert_eq!(fitted.1 % 8, 0);
        assert!((fitted.0 as f64 / fitted.1 as f64 - 4.0 / 3.0).abs() < 0.01);
    }


    #[test]
    fn source_grid_composition_keeps_subrect_offsets_when_scaled() {
        let mut canvas = vec![0u8; 6 * 4 * BYTES_PER_PIXEL];
        fill_rect(
            &mut canvas,
            6,
            4,
            Rect {
                x: 0,
                y: 0,
                width: 6,
                height: 4,
            },
            [0, 0, 0, 255],
        );
        composite(
            &mut canvas,
            6,
            4,
            Rect {
                x: 1,
                y: 0,
                width: 2,
                height: 2,
            },
            &[255, 0, 0, 255].repeat(4),
            false,
        )
        .unwrap();
        composite(
            &mut canvas,
            6,
            4,
            Rect {
                x: 3,
                y: 2,
                width: 2,
                height: 2,
            },
            &[0, 0, 255, 255].repeat(4),
            false,
        )
        .unwrap();

        let scaled = scale_rgba(&canvas, 6, 4, 12, 8).unwrap();
        assert_eq!(pixel(&scaled, 12, 3, 1), [255, 0, 0, 255]);
        assert_eq!(pixel(&scaled, 12, 7, 5), [0, 0, 255, 255]);
        assert_eq!(pixel(&scaled, 12, 10, 1), [0, 0, 0, 255]);
    }

    #[test]
    fn source_over_blends_straight_alpha() {
        let mut target = [0, 0, 255, 255];
        blend_source_over(&mut target, &[255, 0, 0, 128]);
        assert!((target[0] as i32 - 128).abs() <= 1);
        assert_eq!(target[1], 0);
        assert!((target[2] as i32 - 127).abs() <= 1);
        assert_eq!(target[3], 255);
    }

}

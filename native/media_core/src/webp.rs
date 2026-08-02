use std::os::raw::{c_int, c_void};
use std::ptr;

const WEBP_DEMUX_ABI_VERSION: c_int = 0x0107;
const WEBP_DECODER_ABI_VERSION: c_int = 0x0210;
const MODE_RGBA: c_int = 1;
const VP8_STATUS_OK: c_int = 0;
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
#[derive(Clone, Copy)]
struct WebPBitstreamFeatures {
    width: c_int,
    height: c_int,
    has_alpha: c_int,
    has_animation: c_int,
    format: c_int,
    pad: [u32; 5],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct WebPRgbBuffer {
    rgba: *mut u8,
    stride: c_int,
    size: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct WebPYuvaBuffer {
    y: *mut u8,
    u: *mut u8,
    v: *mut u8,
    a: *mut u8,
    y_stride: c_int,
    u_stride: c_int,
    v_stride: c_int,
    a_stride: c_int,
    y_size: usize,
    u_size: usize,
    v_size: usize,
    a_size: usize,
}

#[repr(C)]
union WebPBufferUnion {
    rgba: WebPRgbBuffer,
    yuva: WebPYuvaBuffer,
}

#[repr(C)]
struct WebPDecBuffer {
    colorspace: c_int,
    width: c_int,
    height: c_int,
    is_external_memory: c_int,
    buffer: WebPBufferUnion,
    pad: [u32; 4],
    private_memory: *mut u8,
}

#[repr(C)]
struct WebPDecoderOptions {
    bypass_filtering: c_int,
    no_fancy_upsampling: c_int,
    use_cropping: c_int,
    crop_left: c_int,
    crop_top: c_int,
    crop_width: c_int,
    crop_height: c_int,
    use_scaling: c_int,
    scaled_width: c_int,
    scaled_height: c_int,
    use_threads: c_int,
    dithering_strength: c_int,
    flip: c_int,
    alpha_dithering_strength: c_int,
    pad: [u32; 5],
}

#[repr(C)]
struct WebPDecoderConfig {
    input: WebPBitstreamFeatures,
    output: WebPDecBuffer,
    options: WebPDecoderOptions,
}

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

    fn WebPInitDecoderConfigInternal(
        config: *mut WebPDecoderConfig,
        version: c_int,
    ) -> c_int;
    fn WebPDecode(
        data: *const u8,
        data_size: usize,
        config: *mut WebPDecoderConfig,
    ) -> c_int;
    fn WebPFreeDecBuffer(buffer: *mut WebPDecBuffer);
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
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

#[derive(Clone, Copy, Debug)]
struct FrameDescriptor {
    x_offset: usize,
    y_offset: usize,
    width: usize,
    height: usize,
    duration_ms: u64,
    dispose_background: bool,
    blend: bool,
    complete: bool,
    fragment_offset: usize,
    fragment_length: usize,
}

struct DemuxSnapshot {
    source_length: usize,
    sealed: bool,
    source_width: usize,
    source_height: usize,
    background: [u8; 4],
    meta: AnimationMeta,
    frames: Vec<FrameDescriptor>,
}

impl DemuxSnapshot {
    fn parse(bytes: &[u8], sealed: bool) -> Result<Self, DecodeError> {
        let data = WebPData {
            bytes: bytes.as_ptr(),
            size: bytes.len(),
        };
        let mut state = WEBP_DEMUX_PARSING_HEADER;
        let demux_ptr = unsafe {
            WebPDemuxInternal(&data, 1, &mut state, WEBP_DEMUX_ABI_VERSION)
        };
        if demux_ptr.is_null() {
            return Err(if sealed {
                DecodeError::Failed
            } else {
                DecodeError::NeedMoreData
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
        let background_value = unsafe { WebPDemuxGetI(demux.0, WEBP_FF_BACKGROUND_COLOR) };
        let background = [
            ((background_value >> 16) & 0xff) as u8,
            ((background_value >> 8) & 0xff) as u8,
            (background_value & 0xff) as u8,
            ((background_value >> 24) & 0xff) as u8,
        ];
        let meta = AnimationMeta {
            frame_count: unsafe { WebPDemuxGetI(demux.0, WEBP_FF_FRAME_COUNT) },
            loop_count: unsafe { WebPDemuxGetI(demux.0, WEBP_FF_LOOP_COUNT) },
            complete: state == WEBP_DEMUX_DONE,
        };
        let mut frames = Vec::with_capacity(meta.frame_count as usize);
        let base = bytes.as_ptr() as usize;
        for frame_number in 1..=meta.frame_count {
            let mut raw_iter = unsafe { std::mem::zeroed::<WebPIterator>() };
            if unsafe { WebPDemuxGetFrame(demux.0, frame_number as c_int, &mut raw_iter) } == 0 {
                break;
            }
            let iter = Iter(raw_iter);
            if iter.0.complete == 0
                || iter.0.fragment.bytes.is_null()
                || iter.0.fragment.size == 0
            {
                if sealed || meta.complete {
                    return Err(DecodeError::Failed);
                }
                break;
            }
            if iter.0.width <= 0
                || iter.0.height <= 0
                || iter.0.x_offset < 0
                || iter.0.y_offset < 0
            {
                return Err(DecodeError::Failed);
            }
            let fragment_address = iter.0.fragment.bytes as usize;
            let fragment_length = iter.0.fragment.size;
            let Some(fragment_offset) = fragment_address.checked_sub(base) else {
                return Err(DecodeError::Failed);
            };
            if fragment_offset
                .checked_add(fragment_length)
                .map_or(true, |end| end > bytes.len())
            {
                return Err(DecodeError::Failed);
            }
            frames.push(FrameDescriptor {
                x_offset: iter.0.x_offset as usize,
                y_offset: iter.0.y_offset as usize,
                width: iter.0.width as usize,
                height: iter.0.height as usize,
                duration_ms: iter.0.duration.max(0) as u64,
                dispose_background: iter.0.dispose_method == WEBP_MUX_DISPOSE_BACKGROUND,
                blend: iter.0.blend_method != WEBP_MUX_NO_BLEND,
                complete: iter.0.complete != 0,
                fragment_offset,
                fragment_length,
            });
        }
        Ok(Self {
            source_length: bytes.len(),
            sealed,
            source_width,
            source_height,
            background,
            meta,
            frames,
        })
    }

    fn matches(&self, bytes: &[u8], sealed: bool) -> bool {
        self.source_length == bytes.len() && self.sealed == sealed
    }
}

pub(crate) struct Decoder {
    max_width: usize,
    max_height: usize,
    target_width: usize,
    target_height: usize,
    source_width: usize,
    source_height: usize,
    background: [u8; 4],
    // Blend/disposal remain authoritative in the source pixel grid. The
    // canvas is mutated in place and copied/scaled only once for the immutable
    // output frame, avoiding the prior full-canvas clone before composition.
    canvas: Vec<u8>,
    previous: Option<PreviousFrame>,
    next_frame_number: c_int,
    initialized: bool,
    meta: AnimationMeta,
    ended: bool,
    reset_canvas_before_decode: bool,
    // Cache frame descriptors and offsets across frames, rebuilding only when
    // the incremental source grows or becomes sealed. The authoritative source
    // read lock keeps those offsets stable during decode, so no second full
    // compressed-byte snapshot is retained.
    demux: Option<DemuxSnapshot>,
    #[cfg(test)]
    demux_builds: usize,
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
            reset_canvas_before_decode: false,
            demux: None,
            #[cfg(test)]
            demux_builds: 0,
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
        self.ensure_demux(bytes, sealed)?;
        let (
            meta,
            source_width,
            source_height,
            background,
            descriptor,
            fragment_offset,
            fragment_length,
            demux_complete,
        ) = {
            let snapshot = self.demux.as_ref().ok_or(DecodeError::Failed)?;
            let frame_index = self.next_frame_number.saturating_sub(1) as usize;
            let descriptor = snapshot.frames.get(frame_index).copied();
            let Some(descriptor) = descriptor else {
                if sealed || snapshot.meta.complete {
                    self.ended = true;
                    return Err(DecodeError::End);
                }
                return Err(DecodeError::NeedMoreData);
            };
            (
                snapshot.meta,
                snapshot.source_width,
                snapshot.source_height,
                snapshot.background,
                descriptor,
                descriptor.fragment_offset,
                descriptor.fragment_length,
                snapshot.meta.complete,
            )
        };
        self.meta = meta;
        if !descriptor.complete {
            return Err(if sealed || demux_complete {
                DecodeError::Failed
            } else {
                DecodeError::NeedMoreData
            });
        }
        let source_rect = Rect {
            x: descriptor.x_offset,
            y: descriptor.y_offset,
            width: descriptor.width,
            height: descriptor.height,
        };
        if source_rect.x.saturating_add(source_rect.width) > source_width
            || source_rect.y.saturating_add(source_rect.height) > source_height
        {
            return Err(DecodeError::Failed);
        }
        self.ensure_canvas(background, source_width, source_height)?;
        if self.reset_canvas_before_decode {
            fill_rect(
                &mut self.canvas,
                self.source_width,
                self.source_height,
                Rect {
                    x: 0,
                    y: 0,
                    width: self.source_width,
                    height: self.source_height,
                },
                self.background,
            );
            self.reset_canvas_before_decode = false;
        }

        let source_fragment_len = rgba_len(source_rect.width, source_rect.height)?;
        let fragment_end = fragment_offset
            .checked_add(fragment_length)
            .ok_or(DecodeError::Failed)?;
        if source_fragment_len > MAX_WORKING_BYTES
            || fragment_length == 0
            || fragment_end > bytes.len()
            || source_rect.width > c_int::MAX as usize / BYTES_PER_PIXEL
        {
            return Err(DecodeError::Failed);
        }
        let fragment_ptr = unsafe { bytes.as_ptr().add(fragment_offset) };
        let source_fragment = decode_rgba_threaded(
            fragment_ptr,
            fragment_length,
            source_rect.width,
            source_rect.height,
        )?;

        // Composite the authoritative source canvas in source-grid semantics. The prior dev.82
        // fix rejected independently rounded target rectangles because they
        // can displace animation strips. Mutate the source canvas in place,
        // then produce one presentation-sized immutable snapshot.
        if let Some(previous) = self.previous {
            if previous.dispose_background {
                fill_rect(
                    &mut self.canvas,
                    self.source_width,
                    self.source_height,
                    previous.rect,
                    self.background,
                );
            }
        }
        composite(
            &mut self.canvas,
            self.source_width,
            self.source_height,
            source_rect,
            &source_fragment,
            descriptor.blend,
        )?;

        let duration_us = descriptor.duration_ms.saturating_mul(1_000);
        self.previous = Some(PreviousFrame {
            rect: source_rect,
            dispose_background: descriptor.dispose_background,
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
        self.previous = None;
        self.next_frame_number = 1;
        self.ended = false;
        // Rewind is called from the session isolate. Defer the potentially
        // multi-megabyte canvas clear to the next decode worker invocation.
        self.reset_canvas_before_decode = self.initialized;
        // Keep the descriptor snapshot and fitted canvas. Rewind changes
        // playback state, not source identity or presentation geometry.
    }

    fn ensure_demux(&mut self, bytes: &[u8], sealed: bool) -> Result<(), DecodeError> {
        if let Some(snapshot) = self.demux.as_ref() {
            if snapshot.matches(bytes, sealed) {
                return Ok(());
            }
        }
        self.demux = Some(DemuxSnapshot::parse(bytes, sealed)?);
        #[cfg(test)]
        {
            self.demux_builds = self.demux_builds.saturating_add(1);
        }
        Ok(())
    }

    fn ensure_canvas(
        &mut self,
        background: [u8; 4],
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
        let canvas_len = rgba_len(source_width, source_height)?;
        let target_len = rgba_len(target_width, target_height)?;
        if canvas_len > MAX_WORKING_BYTES
            || target_len > MAX_WORKING_BYTES
            || canvas_len.saturating_add(target_len) > MAX_WORKING_BYTES
        {
            return Err(DecodeError::Failed);
        }
        self.target_width = target_width;
        self.target_height = target_height;
        self.source_width = source_width;
        self.source_height = source_height;
        self.background = background;
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


fn decode_rgba_threaded(
    data: *const u8,
    data_length: usize,
    width: usize,
    height: usize,
) -> Result<Vec<u8>, DecodeError> {
    if data.is_null()
        || data_length == 0
        || width == 0
        || height == 0
        || width > c_int::MAX as usize / BYTES_PER_PIXEL
        || height > c_int::MAX as usize
    {
        return Err(DecodeError::Failed);
    }
    let output_length = rgba_len(width, height)?;
    if output_length > MAX_WORKING_BYTES {
        return Err(DecodeError::Failed);
    }
    let mut output = vec![0u8; output_length];
    let mut config = unsafe { std::mem::zeroed::<WebPDecoderConfig>() };
    if unsafe {
        WebPInitDecoderConfigInternal(&mut config, WEBP_DECODER_ABI_VERSION)
    } == 0
    {
        return Err(DecodeError::Failed);
    }
    config.options.use_threads = 1;
    config.output.colorspace = MODE_RGBA;
    config.output.is_external_memory = 1;
    config.output.buffer = WebPBufferUnion {
        rgba: WebPRgbBuffer {
            rgba: output.as_mut_ptr(),
            stride: (width * BYTES_PER_PIXEL) as c_int,
            size: output.len(),
        },
    };
    let status = unsafe { WebPDecode(data, data_length, &mut config) };
    let dimensions_match = config.output.width == width as c_int
        && config.output.height == height as c_int;
    unsafe { WebPFreeDecBuffer(&mut config.output) };
    if status != VP8_STATUS_OK || !dimensions_match {
        return Err(DecodeError::Failed);
    }
    Ok(output)
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
    fn sealed_source_reuses_demux_across_frames_and_rewind() {
        let bytes = include_bytes!("../testdata/animated.webp");
        let mut decoder = Decoder::new(512, 512);
        let first = decoder.decode_next(bytes, true).unwrap();
        assert_eq!(decoder.demux_builds, 1);
        assert_eq!(first.bytes.len(), (first.width * first.height * 4) as usize);

        decoder.rewind();
        let repeated = decoder.decode_next(bytes, true).unwrap();
        assert_eq!(decoder.demux_builds, 1);
        assert_eq!((repeated.width, repeated.height), (first.width, first.height));
    }

    #[test]
    fn source_grid_composition_keeps_subrect_offsets_when_scaled() {
        let mut canvas = vec![0u8; 6 * 4 * BYTES_PER_PIXEL];
        fill_rect(
            &mut canvas,
            6,
            4,
            Rect { x: 0, y: 0, width: 6, height: 4 },
            [0, 0, 0, 255],
        );
        composite(
            &mut canvas,
            6,
            4,
            Rect { x: 1, y: 0, width: 2, height: 2 },
            &[255, 0, 0, 255].repeat(4),
            false,
        )
        .unwrap();
        composite(
            &mut canvas,
            6,
            4,
            Rect { x: 3, y: 2, width: 2, height: 2 },
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

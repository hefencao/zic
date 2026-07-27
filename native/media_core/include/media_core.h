#ifndef ZIC_MEDIA_CORE_H
#define ZIC_MEDIA_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ByteSource zic_byte_source;
typedef struct Cursor zic_cursor;
typedef struct FrameHandle zic_frame;

typedef enum zic_status {
  ZIC_STATUS_OK = 0,
  ZIC_STATUS_NULL = 1,
  ZIC_STATUS_STALE_EPOCH = 2,
  ZIC_STATUS_INVALID_OFFSET = 3,
  ZIC_STATUS_SEALED = 4,
  ZIC_STATUS_BUDGET = 5,
  ZIC_STATUS_FAILED = 6
} zic_status;

typedef enum zic_cursor_status {
  ZIC_CURSOR_OK = 0,
  ZIC_CURSOR_NULL = 1,
  ZIC_CURSOR_STALE_EPOCH = 2,
  ZIC_CURSOR_NEED_MORE_DATA = 3,
  ZIC_CURSOR_END = 4,
  ZIC_CURSOR_UNSUPPORTED = 5,
  ZIC_CURSOR_FAILED = 6
} zic_cursor_status;

typedef enum zic_container_kind {
  ZIC_CONTAINER_UNKNOWN = 0,
  ZIC_CONTAINER_WEBP = 1,
  ZIC_CONTAINER_GIF = 2,
  ZIC_CONTAINER_OTHER = 3
} zic_container_kind;

typedef enum zic_pixel_format {
  ZIC_PIXEL_RGBA8888 = 0
} zic_pixel_format;

uint32_t zic_abi_version(void);
uint32_t zic_version(void);
uint32_t zic_webp_decoder_version(void);
uint32_t zic_webp_demux_version(void);

zic_byte_source *zic_source_create(uint64_t epoch, size_t max_bytes);
void zic_source_free(zic_byte_source *source);
uint32_t zic_source_append(zic_byte_source *source, uint64_t epoch,
                           size_t offset, const uint8_t *data, size_t len);
uint32_t zic_source_seal(zic_byte_source *source, uint64_t epoch);
uint32_t zic_source_reset(zic_byte_source *source, uint64_t epoch);
size_t zic_source_len(const zic_byte_source *source);
uint64_t zic_source_epoch(const zic_byte_source *source);
uint32_t zic_source_is_sealed(const zic_byte_source *source);
uint32_t zic_source_kind(const zic_byte_source *source);

zic_cursor *zic_cursor_create(const zic_byte_source *source, uint64_t epoch,
                              uint32_t target_width,
                              uint32_t target_height);
void zic_cursor_free(zic_cursor *cursor);
uint64_t zic_cursor_epoch(const zic_cursor *cursor);
uint32_t zic_cursor_decode_next(zic_cursor *cursor, uint64_t epoch,
                                zic_frame **out_frame);
uint32_t zic_cursor_frame_count(const zic_cursor *cursor);
uint32_t zic_cursor_loop_count(const zic_cursor *cursor);
uint32_t zic_cursor_metadata_complete(const zic_cursor *cursor);
uint32_t zic_cursor_cycle(const zic_cursor *cursor);
uint32_t zic_cursor_rewind(zic_cursor *cursor, uint64_t epoch);

zic_frame *zic_frame_retain(const zic_frame *frame);
void zic_frame_release(zic_frame *frame);
uint64_t zic_frame_epoch(const zic_frame *frame);
uint32_t zic_frame_index(const zic_frame *frame);
uint32_t zic_frame_cycle(const zic_frame *frame);
uint32_t zic_frame_width(const zic_frame *frame);
uint32_t zic_frame_height(const zic_frame *frame);
uint64_t zic_frame_duration_us(const zic_frame *frame);
uint32_t zic_frame_format(const zic_frame *frame);
size_t zic_frame_len(const zic_frame *frame);
const uint8_t *zic_frame_data(const zic_frame *frame);

#ifdef __cplusplus
}
#endif

#endif

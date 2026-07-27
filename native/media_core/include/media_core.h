#ifndef ZIC_MEDIA_CORE_H
#define ZIC_MEDIA_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ByteSource zic_byte_source;

typedef enum zic_status {
  ZIC_STATUS_OK = 0,
  ZIC_STATUS_NULL = 1,
  ZIC_STATUS_STALE_EPOCH = 2,
  ZIC_STATUS_INVALID_OFFSET = 3,
  ZIC_STATUS_SEALED = 4,
  ZIC_STATUS_BUDGET = 5
} zic_status;

typedef enum zic_container_kind {
  ZIC_CONTAINER_UNKNOWN = 0,
  ZIC_CONTAINER_WEBP = 1,
  ZIC_CONTAINER_GIF = 2,
  ZIC_CONTAINER_OTHER = 3
} zic_container_kind;

uint32_t zic_abi_version(void);
uint32_t zic_version(void);

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

#ifdef __cplusplus
}
#endif

#endif

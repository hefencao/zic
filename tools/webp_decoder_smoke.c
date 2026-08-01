#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <webp/decode.h>
#include <webp/demux.h>

static uint8_t *read_file(const char *path, size_t *size) {
  FILE *file = fopen(path, "rb");
  if (file == NULL) return NULL;
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return NULL;
  }
  long length = ftell(file);
  if (length <= 0 || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return NULL;
  }
  uint8_t *bytes = (uint8_t *)malloc((size_t)length);
  if (bytes == NULL || fread(bytes, 1, (size_t)length, file) != (size_t)length) {
    free(bytes);
    fclose(file);
    return NULL;
  }
  fclose(file);
  *size = (size_t)length;
  return bytes;
}


static int check_all_prefixes(const uint8_t *bytes, size_t size) {
  for (size_t length = 1; length <= size; ++length) {
    WebPData data = {bytes, length};
    WebPDemuxState state = WEBP_DEMUX_PARSING_HEADER;
    WebPDemuxer *demux = WebPDemuxPartial(&data, &state);
    if (state == WEBP_DEMUX_PARSE_ERROR) {
      if (demux != NULL) WebPDemuxDelete(demux);
      fprintf(stderr, "valid fixture prefix %zu/%zu parsed as error\n", length,
              size);
      return 0;
    }
    if (demux != NULL) {
      uint32_t frame_count = WebPDemuxGetI(demux, WEBP_FF_FRAME_COUNT);
      for (uint32_t frame_number = 1; frame_number <= frame_count;
           ++frame_number) {
        WebPIterator iter;
        if (WebPDemuxGetFrame(demux, (int)frame_number, &iter)) {
          if (iter.complete &&
              (iter.fragment.bytes == NULL || iter.fragment.size == 0)) {
            WebPDemuxReleaseIterator(&iter);
            WebPDemuxDelete(demux);
            fprintf(stderr, "complete frame has no fragment at prefix %zu\n",
                    length);
            return 0;
          }
          WebPDemuxReleaseIterator(&iter);
        }
      }
      WebPDemuxDelete(demux);
    }
  }
  return 1;
}

static int check_first_frame_before_complete(const uint8_t *bytes, size_t size) {
  for (size_t length = 12; length < size; ++length) {
    WebPData data = {bytes, length};
    WebPDemuxState state = WEBP_DEMUX_PARSING_HEADER;
    WebPDemuxer *demux = WebPDemuxPartial(&data, &state);
    if (demux == NULL) continue;
    WebPIterator iter;
    int found = WebPDemuxGetFrame(demux, 1, &iter);
    int complete = found && iter.complete && iter.fragment.bytes != NULL &&
                   iter.fragment.size > 0;
    if (found) WebPDemuxReleaseIterator(&iter);
    WebPDemuxDelete(demux);
    if (complete) return state != WEBP_DEMUX_DONE;
  }
  return 0;
}

static int check_frame(const WebPDemuxer *demux, int frame_number,
                       int expected_duration_ms,
                       const uint8_t expected[4]) {
  WebPIterator iter;
  if (!WebPDemuxGetFrame(demux, frame_number, &iter)) return 0;
  int ok = 0;
  if (iter.complete && iter.width == 2 && iter.height == 2 &&
      iter.duration == expected_duration_ms) {
    uint8_t rgba[16];
    if (WebPDecodeRGBAInto(iter.fragment.bytes, iter.fragment.size, rgba,
                           sizeof(rgba), 8) != NULL) {
      ok = 1;
      for (size_t offset = 0; offset < sizeof(rgba); offset += 4) {
        if (memcmp(rgba + offset, expected, 4) != 0) {
          ok = 0;
          break;
        }
      }
    }
  }
  WebPDemuxReleaseIterator(&iter);
  return ok;
}

static int check_partial_blend_fixture(const char *path) {
  size_t size = 0;
  uint8_t *bytes = read_file(path, &size);
  if (bytes == NULL) return 0;
  if (!check_all_prefixes(bytes, size)) {
    free(bytes);
    return 0;
  }
  WebPData data = {bytes, size};
  WebPDemuxer *demux = WebPDemux(&data);
  if (demux == NULL) {
    free(bytes);
    return 0;
  }
  WebPIterator iter;
  int ok = WebPDemuxGetFrame(demux, 2, &iter);
  if (ok) {
    uint8_t rgba[4];
    uint8_t *decoded = WebPDecodeRGBAInto(iter.fragment.bytes,
                                          iter.fragment.size, rgba,
                                          sizeof(rgba), 4);
    ok = iter.complete && iter.x_offset == 2 && iter.y_offset == 2 &&
         iter.width == 1 && iter.height == 1 &&
         iter.blend_method == WEBP_MUX_BLEND && decoded != NULL &&
         rgba[0] == 0 && rgba[1] == 255 && rgba[2] == 0 && rgba[3] == 128;
    WebPDemuxReleaseIterator(&iter);
  }
  WebPDemuxDelete(demux);
  free(bytes);
  return ok;
}


static int check_finite_loop_fixture(const char *path) {
  size_t size = 0;
  uint8_t *bytes = read_file(path, &size);
  if (bytes == NULL) return 0;
  if (!check_all_prefixes(bytes, size)) {
    free(bytes);
    return 0;
  }
  WebPData data = {bytes, size};
  WebPDemuxer *demux = WebPDemux(&data);
  if (demux == NULL) {
    free(bytes);
    return 0;
  }
  int ok = WebPDemuxGetI(demux, WEBP_FF_FRAME_COUNT) == 2 &&
           WebPDemuxGetI(demux, WEBP_FF_LOOP_COUNT) == 2;
  WebPDemuxDelete(demux);
  free(bytes);
  return ok;
}

int main(int argc, char **argv) {
  if (WebPGetDecoderVersion() != 0x010600 ||
      WebPGetDemuxVersion() != 0x010600) {
    fprintf(stderr, "unexpected libwebp version: decoder=%06x demux=%06x\n",
            WebPGetDecoderVersion(), WebPGetDemuxVersion());
    return 11;
  }
  if (argc != 4) {
    fprintf(stderr,
            "usage: %s animated.webp partial_blend.webp finite_loop.webp\n",
            argv[0]);
    return 2;
  }
  size_t size = 0;
  uint8_t *bytes = read_file(argv[1], &size);
  if (bytes == NULL) {
    fprintf(stderr, "failed to read fixture\n");
    return 3;
  }

  if (!check_all_prefixes(bytes, size)) {
    free(bytes);
    return 4;
  }
  if (!check_first_frame_before_complete(bytes, size)) {
    fprintf(stderr, "first animation frame was not available before seal\n");
    free(bytes);
    return 12;
  }

  WebPData prefix = {bytes, size < 12 ? size : 12};
  WebPDemuxState prefix_state = WEBP_DEMUX_PARSING_HEADER;
  WebPDemuxer *partial = WebPDemuxPartial(&prefix, &prefix_state);
  if (partial != NULL) WebPDemuxDelete(partial);
  if (prefix_state == WEBP_DEMUX_PARSE_ERROR) {
    fprintf(stderr, "valid prefix parsed as error\n");
    free(bytes);
    return 5;
  }

  WebPData data = {bytes, size};
  WebPDemuxState state = WEBP_DEMUX_PARSING_HEADER;
  WebPDemuxer *demux = WebPDemuxPartial(&data, &state);
  if (demux == NULL || state != WEBP_DEMUX_DONE) {
    fprintf(stderr, "full fixture did not finish demux\n");
    if (demux != NULL) WebPDemuxDelete(demux);
    free(bytes);
    return 6;
  }
  if (WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH) != 2 ||
      WebPDemuxGetI(demux, WEBP_FF_CANVAS_HEIGHT) != 2 ||
      WebPDemuxGetI(demux, WEBP_FF_FRAME_COUNT) != 2) {
    fprintf(stderr, "unexpected animation metadata\n");
    WebPDemuxDelete(demux);
    free(bytes);
    return 7;
  }

  const uint8_t red[4] = {255, 0, 0, 255};
  const uint8_t green[4] = {0, 255, 0, 255};
  if (!check_frame(demux, 1, 80, red) ||
      !check_frame(demux, 2, 120, green)) {
    fprintf(stderr, "decoded frame content mismatch\n");
    WebPDemuxDelete(demux);
    free(bytes);
    return 8;
  }

  WebPDemuxDelete(demux);
  free(bytes);
  if (!check_partial_blend_fixture(argv[2])) {
    fprintf(stderr, "partial blend fixture mismatch\n");
    return 9;
  }
  if (!check_finite_loop_fixture(argv[3])) {
    fprintf(stderr, "finite loop fixture mismatch\n");
    return 10;
  }
  printf("libwebp incremental and loop fixtures: OK\n");
  return 0;
}

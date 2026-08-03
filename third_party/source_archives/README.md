# Pinned source archives

`libwebp-1.6.0.zip` is the exact libwebp 1.6.0 source archive used by ZIC's
host and Android native builds. Its SHA-256 and the clean `src/dec/vp8_dec.c`
SHA-256 are locked in `native/libwebp.lock`.

The archive is an immutable build input. `tool/fetch_webp.sh` extracts it into
`.deps/src/upstream/`; `tool/prepare_webp.sh` copies that clean tree and applies
ZIC's local VP8 TLS workspace patch in a separate prepared directory. Neither
script edits this archive or the upstream cache in place.

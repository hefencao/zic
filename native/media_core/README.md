# media_core

Rust owns incremental encoded-byte sources, cursor handles, and immutable frame
handles behind a stable C ABI.

Current ABI version: **3**.

The ownership boundary is complete, but a real Animated WebP decoder is not yet
linked. `zic_cursor_decode_next` returns `needMoreData` for incomplete input and
`unsupported` for sealed WebP input rather than fabricating a frame.

```bash
cargo test -p media_core
cargo build -p media_core --release
```

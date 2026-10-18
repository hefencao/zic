# Vendored PaddleOCR Android SDK

- Upstream: https://github.com/PaddlePaddle/PaddleOCR
- Revision: `211989f046cc1878460f9e65574690c00a127a1a`
- Source directory: `deploy/ppocr-android/ppocr-sdk`
- License: Apache-2.0; see `LICENSE`.

Venera keeps the upstream asset-loading API and extends the explicit-path
constructor to load models downloaded into app support storage. The module
minimum SDK is lowered from 26 to Venera's existing 24; the vendored source
does not call API 25/26-only Android APIs. The obsolete QuickBird OpenCV 4.5.3
AAR is replaced in the host plugin by OpenCV 4.13.0's pinned OCR module build
(`core`, `imgproc`, `imgcodecs`, `photo` and Java JNI). The host uses
`dev.zic.thirdparty:opencv-ocr:4.13.0-ocr1`, prepared by
`tool/comic_translation/prepare_opencv_android.py`; the standalone vendored
Gradle descriptor is not part of that host build. The exact upstream Java
classes/resources are retained, and the native OCR JNI surface is checked
against the official AAR. TBB, SIMD dispatch and each ABI's original HAL
accelerators remain enabled. Image codecs, ONNX operators and model identities
are unchanged; build revisions and third-party licenses accompany the APK.

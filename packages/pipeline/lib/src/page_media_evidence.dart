import 'package:domain/domain.dart';

const _staticImageSuffixes = <String>[
  '.jpg',
  '.jpeg',
  '.jpe',
  '.png',
  '.avif',
  '.bmp',
  '.dib',
  '.tif',
  '.tiff',
  '.ico',
  '.heif',
  '.heic',
];

bool hasWebpUriSuffix(Uri uri) =>
    uri.path.toLowerCase().endsWith('.webp');

/// Whether a URI suffix already proves the encoded image is not WebP.
///
/// This is container evidence only. GIF remains potentially animated, while
/// the remaining suffixes are static-image evidence.
bool hasKnownNonWebpImageSuffix(Uri uri) {
  final path = uri.path.toLowerCase();
  return path.endsWith('.gif') || _staticImageSuffixes.any(path.endsWith);
}

/// Conservative encoded-cost evidence for a WebP whose animation capability
/// has not yet been resolved by the decoder.
///
/// A manifest format hint or `.webp` URI identifies the container only; it
/// does not prove that the file is static. Runtime sniffing supplies the same
/// fact for opaque resource URIs.
bool hasWebpCostEvidence(
  PageAsset page, {
  bool runtimeObserved = false,
}) =>
    runtimeObserved ||
    page.contentKindHint == ContentKindHint.webp ||
    hasWebpUriSuffix(page.uri);

/// Positive source-level evidence that an unclassified page uses a static
/// image container.
///
/// `animatedHint == false` is intentionally not enough: it is the default for
/// manifests that omit animation metadata. Opaque URIs likewise remain
/// unresolved until the decoder classifies them or chapter-level static
/// inference becomes authoritative enough for one-frame warming.
bool hasStaticContentEvidence(PageAsset page) {
  if (page.animatedHint) return false;
  switch (page.contentKindHint) {
    case ContentKindHint.jpeg:
    case ContentKindHint.png:
    case ContentKindHint.avif:
    case ContentKindHint.fallback:
      return true;
    case ContentKindHint.webp:
    case ContentKindHint.gif:
      return false;
    case ContentKindHint.unknown:
      break;
  }
  final path = page.uri.path.toLowerCase();
  return _staticImageSuffixes.any(path.endsWith);
}

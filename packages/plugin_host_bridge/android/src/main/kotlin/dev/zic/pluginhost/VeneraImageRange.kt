package dev.zic.pluginhost

/**
 * Validates Venera's Image.fillImageRangeAt contract.
 *
 * Venera permits zero-area ranges: its reference implementation simply runs
 * zero copy-loop iterations. Keep that behavior because source scripts (JM in
 * particular) can intentionally produce zero-height blocks when the decoded
 * image is shorter than the scramble block count.
 *
 * Returns true when the validated range is empty and therefore a no-op.
 */
internal fun validateVeneraImageFillRange(
    targetWidth: Int,
    targetHeight: Int,
    sourceWidth: Int,
    sourceHeight: Int,
    x: Int,
    y: Int,
    srcX: Int,
    srcY: Int,
    width: Int,
    height: Int,
): Boolean {
    require(width >= 0 && height >= 0) {
        "Venera image range size is negative " +
            "(width=$width, height=$height)"
    }
    require(
        x >= 0 && y >= 0 &&
            x.toLong() + width <= targetWidth.toLong() &&
            y.toLong() + height <= targetHeight.toLong(),
    ) {
        "Venera image target range is out of bounds " +
            "(target=${targetWidth}x$targetHeight, x=$x, y=$y, " +
            "width=$width, height=$height)"
    }
    require(
        srcX >= 0 && srcY >= 0 &&
            srcX.toLong() + width <= sourceWidth.toLong() &&
            srcY.toLong() + height <= sourceHeight.toLong(),
    ) {
        "Venera image source range is out of bounds " +
            "(source=${sourceWidth}x$sourceHeight, srcX=$srcX, srcY=$srcY, " +
            "width=$width, height=$height)"
    }
    return width == 0 || height == 0
}

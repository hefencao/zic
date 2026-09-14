import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';

final class ReaderTransferProgressFeedIndicator extends StatefulWidget {
  const ReaderTransferProgressFeedIndicator({
    super.key,
    required this.feed,
    required this.networkKey,
    required this.partialKey,
  });

  final PipelineTransferProgressFeed feed;
  final Key networkKey;
  final Key partialKey;

  @override
  State<ReaderTransferProgressFeedIndicator> createState() =>
      _ReaderTransferProgressFeedIndicatorState();
}

final class _ReaderTransferProgressFeedIndicatorState
    extends State<ReaderTransferProgressFeedIndicator> {
  late PipelineTransferProgress _progress;

  @override
  void initState() {
    super.initState();
    _attach(widget.feed);
  }

  @override
  void didUpdateWidget(
    covariant ReaderTransferProgressFeedIndicator oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.feed, widget.feed)) {
      oldWidget.feed.removeListener(_onProgress);
      _attach(widget.feed);
    }
  }

  void _attach(PipelineTransferProgressFeed feed) {
    _progress = feed.value;
    feed.addListener(_onProgress, fireImmediately: false);
  }

  void _onProgress(PipelineTransferProgress progress) {
    if (!mounted || _progress == progress) return;
    setState(() => _progress = progress);
  }

  @override
  void dispose() {
    widget.feed.removeListener(_onProgress);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ReaderTransferProgressIndicator(
        progress: _progress,
        networkKey: widget.networkKey,
        partialKey: widget.partialKey,
      );
}

final class ReaderTransferProgressIndicator extends StatelessWidget {
  const ReaderTransferProgressIndicator({
    super.key,
    required this.progress,
    required this.networkKey,
    required this.partialKey,
  });

  final PipelineTransferProgress progress;
  final Key networkKey;
  final Key partialKey;

  @override
  Widget build(BuildContext context) {
    if (!progress.active && progress.partialBytes <= 0) {
      return const SizedBox(height: 6);
    }
    final total = progress.displayTotalBytes;
    final partial = progress.partialFraction;
    final transport = progress.transportFraction;
    final theme = Theme.of(context);
    final waveColor = _downloadSpeedColor(progress.speedBytesPerSecond);
    final hasPartial = progress.partialBytes > 0;
    final hasScale = total != null &&
        total > 0 &&
        partial != null &&
        transport != null;

    final semanticsLabel = !progress.active && hasPartial
        ? '已有页面partial'
        : switch (progress.phase) {
            PipelineTransferPhase.replayingPrefix => '已有页面partial，正在重读页面前缀',
            PipelineTransferPhase.receiving => hasPartial
                ? '已有页面partial，正在接收页面数据'
                : '正在接收页面数据',
            PipelineTransferPhase.connecting => hasPartial
                ? '已有页面partial，正在连接页面资源'
                : '正在连接页面资源',
            PipelineTransferPhase.idle => '已有页面partial',
          };
    final semanticsValue = <String>[
      if (hasPartial && total != null)
        '已有partial ${progress.partialBytes}/$total bytes'
      else if (hasPartial)
        '已有partial ${progress.partialBytes} bytes',
      if (progress.active && !progress.transportAttemptActive)
        '正在连接'
      else if (progress.phase == PipelineTransferPhase.replayingPrefix)
        '正在重读 ${progress.transportBytes}/${progress.partialBytes} bytes'
      else if (progress.active && progress.transportAttemptActive && total != null)
        '当前传输 ${progress.transportBytes}/$total bytes'
      else if (progress.active && progress.transportAttemptActive)
        '当前传输 ${progress.transportBytes} bytes',
    ].join('；');

    return Semantics(
      label: semanticsLabel,
      value: semanticsValue.isEmpty ? null : semanticsValue,
      child: SizedBox(
        height: 6,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.hasBoundedWidth
                ? constraints.maxWidth
                : 0.0;
            final partialStart = hasScale && progress.transportAttemptActive
                ? math.min(transport, partial)
                : 0.0;
            final partialEnd = hasScale ? partial : 0.0;
            final partialWidth = math.max(0.0, partialEnd - partialStart) * width;
            final showConnecting = progress.active &&
                (!progress.transportAttemptActive ||
                    transport == null ||
                    transport <= 0);
            final showWave = progress.transportAttemptActive &&
                transport != null &&
                transport > 0;

            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (hasPartial && hasScale && partialWidth > 0)
                  Positioned(
                    left: width * partialStart,
                    top: 2.25,
                    width: partialWidth,
                    height: 1.5,
                    child: SizedBox(
                      key: partialKey,
                      child: ColoredBox(color: theme.colorScheme.secondary),
                    ),
                  ),
                if (showConnecting)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: double.infinity,
                      height: 1.5,
                      child: LinearProgressIndicator(
                        key: networkKey,
                        value: null,
                        minHeight: 1.5,
                        color: progress.transportAttemptActive
                            ? waveColor
                            : theme.colorScheme.outline,
                        backgroundColor: Colors.transparent,
                      ),
                    ),
                  )
                else if (showWave)
                  CustomPaint(
                    key: networkKey,
                    painter: _TransferWavePainter(
                      fraction: transport,
                      color: waveColor,
                    ),
                  )
                else
                  SizedBox(key: networkKey),
              ],
            );
          },
        ),
      ),
    );
  }

}

/// VibeVenera's Reader progress uses a logarithmic speed ramp so low-rate
/// transfers remain visibly red while useful throughput moves through amber
/// toward green. ZIC applies that presentation only to the transient transport
/// wave. The authoritative partial uses the same horizontal lane and is
/// only drawn for the still-local range beyond the current transport cursor.
Color _downloadSpeedColor(double bytesPerSecond) {
  const base = 128 * 1024.0;
  const max = 8 * 1024 * 1024.0;
  final t = (math.log(1 + bytesPerSecond / base) /
          math.log(1 + max / base))
      .clamp(0.0, 1.0);
  return t < 0.7
      ? Color.lerp(Colors.red, Colors.amber, t / 0.7)!
      : Color.lerp(Colors.amber, Colors.green, (t - 0.7) / 0.3)!;
}

final class _TransferWavePainter extends CustomPainter {
  const _TransferWavePainter({
    required this.fraction,
    required this.color,
  });

  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || fraction <= 0) return;
    final endX = size.width * fraction.clamp(0.0, 1.0);
    if (endX <= 0) return;
    const wavelength = 12.0;
    final amplitude = math.min(1.4, size.height * 0.28);
    final centerY = size.height / 2;
    final path = Path()..moveTo(0, centerY);
    for (var x = 1.0; x <= endX; x += 1.0) {
      final y = centerY +
          math.sin((x / wavelength) * math.pi * 2) * amplitude;
      path.lineTo(x, y);
    }
    if (endX % 1.0 != 0) {
      final y = centerY +
          math.sin((endX / wavelength) * math.pi * 2) * amplitude;
      path.lineTo(endX, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.7
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _TransferWavePainter oldDelegate) =>
      oldDelegate.fraction != fraction || oldDelegate.color != color;
}

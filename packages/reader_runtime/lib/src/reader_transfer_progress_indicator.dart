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
    final total = progress.totalBytes;
    final partial = progress.partialFraction;
    final transport = progress.transportFraction;
    final theme = Theme.of(context);
    final waveColor = _downloadSpeedColor(progress.speedBytesPerSecond);

    if (total == null || total <= 0 || partial == null || transport == null) {
      final receiving = progress.transportAttemptActive;
      final hasPartial = progress.partialBytes > 0;
      final replayingPrefix =
          progress.phase == PipelineTransferPhase.replayingPrefix;
      final semanticsLabel = !progress.active && hasPartial
          ? '已有页面partial'
          : switch (progress.phase) {
              PipelineTransferPhase.replayingPrefix => '正在重读已有页面前缀',
              PipelineTransferPhase.receiving => hasPartial
                  ? '已有页面partial，正在接收页面数据'
                  : '正在接收页面数据',
              PipelineTransferPhase.connecting => hasPartial
                  ? '已有页面partial，正在连接页面资源'
                  : '正在连接页面资源',
              PipelineTransferPhase.idle => '已有页面partial',
            };
      final semanticsValue = <String>[
        if (hasPartial) '已有partial ${progress.partialBytes} bytes',
        if (replayingPrefix)
          '重读 ${progress.transportBytes}/${progress.partialBytes} bytes'
        else if (progress.active && receiving)
          '当前传输 ${progress.transportBytes} bytes',
      ].join('；');
      return Semantics(
        label: semanticsLabel,
        value: semanticsValue.isEmpty ? null : semanticsValue,
        child: SizedBox(
          height: 6,
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.centerLeft,
            children: <Widget>[
              if (progress.active)
                LinearProgressIndicator(
                  key: networkKey,
                  value: replayingPrefix
                      ? (progress.transportBytes / progress.partialBytes)
                          .clamp(0.0, 1.0)
                          .toDouble()
                      : null,
                  minHeight: 3,
                  color: receiving ? waveColor : theme.colorScheme.outline,
                  backgroundColor: Colors.transparent,
                )
              else
                SizedBox(key: networkKey),
              if (hasPartial)
                Align(
                  alignment: Alignment.bottomLeft,
                  child: SizedBox(
                    key: partialKey,
                    width: 12,
                    height: 1.5,
                    child: ColoredBox(color: theme.colorScheme.secondary),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final semanticsLabel = switch (progress.phase) {
      PipelineTransferPhase.replayingPrefix => '正在重读已有页面前缀',
      PipelineTransferPhase.receiving => '正在接收页面数据',
      PipelineTransferPhase.connecting => '正在连接页面资源',
      PipelineTransferPhase.idle => '已有页面partial',
    };
    final semanticsValue = progress.active
        ? '${progress.transportBytes}/$total bytes；'
            '已有partial ${progress.partialBytes}/$total bytes'
        : '已有partial ${progress.partialBytes}/$total bytes';
    return Semantics(
      label: semanticsLabel,
      value: semanticsValue,
      child: SizedBox(
        height: 6,
        child: Stack(
          fit: StackFit.expand,
          alignment: Alignment.centerLeft,
          children: <Widget>[
            if (partial > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  key: partialKey,
                  widthFactor: partial,
                  child: SizedBox(
                    height: 1.5,
                    child: ColoredBox(color: theme.colorScheme.secondary),
                  ),
                ),
              ),
            if (progress.transportAttemptActive && transport > 0)
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
        ),
      ),
    );
  }
}

/// VibeVenera's Reader progress uses a logarithmic speed ramp so low-rate
/// transfers remain visibly red while useful throughput moves through amber
/// toward green. ZIC applies that presentation only to the transient transport
/// wave; the authoritative partial remains a separate theme-secondary line.
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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const readerAnimationControlsKey =
    ValueKey<String>('reader-animation-controls');
const readerPauseKey = ValueKey<String>('reader-pause');
const readerSpeedKey = ValueKey<String>('reader-speed');
Key readerSpeedOptionKey(double speed) =>
    ValueKey<String>('reader-speed-option:$speed');

@immutable
final class ReaderPlaybackState {
  const ReaderPlaybackState({
    this.paused = false,
    this.speed = 1,
  })  : assert(speed >= 0.25),
        assert(speed <= 4);

  final bool paused;
  final double speed;

  ReaderPlaybackState copyWith({bool? paused, double? speed}) =>
      ReaderPlaybackState(
        paused: paused ?? this.paused,
        speed: speed ?? this.speed,
      );
}

final class ReaderPlaybackController
    extends ValueNotifier<ReaderPlaybackState> {
  ReaderPlaybackController() : super(const ReaderPlaybackState());

  void togglePaused() => value = value.copyWith(paused: !value.paused);

  void setSpeed(double speed) {
    if (value.speed == speed) return;
    value = value.copyWith(speed: speed);
  }
}

final class ReaderAnimationControls extends StatelessWidget {
  const ReaderAnimationControls({
    required this.playback,
    required this.onTogglePaused,
    required this.onChooseSpeed,
    required this.speedLabel,
    super.key,
  });

  final ReaderPlaybackController playback;
  final VoidCallback onTogglePaused;
  final VoidCallback onChooseSpeed;
  final String Function(double speed) speedLabel;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ReaderPlaybackState>(
        valueListenable: playback,
        builder: (context, state, _) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Material(
              key: readerAnimationControlsKey,
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    key: readerPauseKey,
                    tooltip: state.paused ? '继续播放' : '暂停动画',
                    onPressed: onTogglePaused,
                    icon: Icon(
                      state.paused ? Icons.play_arrow : Icons.pause,
                      color: Colors.white,
                    ),
                  ),
                  TextButton(
                    key: readerSpeedKey,
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    onPressed: onChooseSpeed,
                    child: Text(speedLabel(state.speed)),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ),
      );
}

/// Owns the narrow rebuild boundary for animation-capability visibility.
/// Fixed Reader controls never subscribe to media classification changes.
final class ReaderAnimationControlsVisibility extends StatelessWidget {
  const ReaderAnimationControlsVisibility({
    required this.currentIndex,
    required this.capabilityRevision,
    required this.isVisible,
    required this.child,
    super.key,
  });

  final ValueListenable<int> currentIndex;
  final ValueListenable<int> capabilityRevision;
  final bool Function() isVisible;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: currentIndex,
        builder: (context, _, _) => ValueListenableBuilder<int>(
          valueListenable: capabilityRevision,
          builder: (context, _, _) =>
              isVisible() ? child : const SizedBox.shrink(),
        ),
      );
}

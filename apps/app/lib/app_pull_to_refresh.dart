import 'package:flutter/material.dart';

/// One pull-to-refresh interaction for source browsing and comic details.
///
/// Both screens retain their current content while [onRefresh] runs. The
/// indicator is visible, edge-triggered, and requires the same displacement so
/// users do not have to learn two refresh gestures.
final class AppPullToRefresh extends StatelessWidget {
  const AppPullToRefresh({
    required this.onRefresh,
    required this.child,
    super.key,
  });

  final RefreshCallback onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      triggerMode: RefreshIndicatorTriggerMode.onEdge,
      displacement: 72,
      edgeOffset: 0,
      onRefresh: onRefresh,
      child: child,
    );
  }
}

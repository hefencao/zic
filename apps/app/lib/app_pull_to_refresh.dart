import 'dart:async';

import 'package:flutter/material.dart';

enum _AppRefreshResult { idle, success, failure }

/// One pull-to-refresh interaction for source browsing and comic details.
///
/// Both screens retain their current content while [onRefresh] runs. The
/// progress indicator, result badge, edge threshold and result lifetime are
/// owned here so pages cannot drift into separate refresh affordances.
final class AppPullToRefresh extends StatefulWidget {
  const AppPullToRefresh({
    required this.onRefresh,
    required this.child,
    this.resultKey,
    super.key,
  });

  final Future<bool> Function() onRefresh;
  final Widget child;
  final Key? resultKey;

  @override
  State<AppPullToRefresh> createState() => _AppPullToRefreshState();
}

final class _AppPullToRefreshState extends State<AppPullToRefresh> {
  static const double _displacement = 72;
  static const double _badgeSize = 40;

  Future<void>? _refreshInFlight;
  Timer? _resultTimer;
  _AppRefreshResult _result = _AppRefreshResult.idle;

  Future<void> _refresh() {
    final active = _refreshInFlight;
    if (active != null) return active;
    late final Future<void> tracked;
    tracked = _performRefresh().whenComplete(() {
      if (identical(_refreshInFlight, tracked)) {
        _refreshInFlight = null;
      }
    });
    _refreshInFlight = tracked;
    return tracked;
  }

  Future<void> _performRefresh() async {
    _resultTimer?.cancel();
    if (_result != _AppRefreshResult.idle && mounted) {
      setState(() => _result = _AppRefreshResult.idle);
    }
    var succeeded = false;
    try {
      succeeded = await widget.onRefresh();
    } on Object {
      succeeded = false;
    }
    if (!mounted) return;
    final result = succeeded
        ? _AppRefreshResult.success
        : _AppRefreshResult.failure;
    setState(() => _result = result);
    _resultTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _result == result) {
        setState(() => _result = _AppRefreshResult.idle);
      }
    });
  }

  @override
  void dispose() {
    _resultTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.topCenter,
      children: <Widget>[
        RefreshIndicator(
          triggerMode: RefreshIndicatorTriggerMode.onEdge,
          displacement: _displacement,
          edgeOffset: 0,
          onRefresh: _refresh,
          child: widget.child,
        ),
        if (_result != _AppRefreshResult.idle)
          Positioned(
            top: _displacement,
            child: IgnorePointer(
              child: Material(
                key: widget.resultKey,
                elevation: 2,
                color: Theme.of(context).colorScheme.surface,
                shape: const CircleBorder(),
                child: SizedBox.square(
                  dimension: _badgeSize,
                  child: Icon(
                    _result == _AppRefreshResult.success
                        ? Icons.check
                        : Icons.close,
                    size: 24,
                    color: _result == _AppRefreshResult.success
                        ? Colors.green
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

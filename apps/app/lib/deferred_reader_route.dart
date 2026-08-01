import 'dart:async';

import 'package:flutter/material.dart';

const deferredReaderRouteKey = ValueKey<String>('deferred-reader-route');
const deferredReaderLoadingKey = ValueKey<String>('deferred-reader-loading');
const deferredReaderErrorKey = ValueKey<String>('deferred-reader-error');
const deferredReaderRetryKey = ValueKey<String>('deferred-reader-retry');

final class DeferredReaderRoute<T> extends StatefulWidget {
  const DeferredReaderRoute({
    required this.title,
    required this.load,
    required this.builder,
    super.key,
  });

  final String title;
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<DeferredReaderRoute<T>> createState() =>
      _DeferredReaderRouteState<T>();
}

final class _DeferredReaderRouteState<T>
    extends State<DeferredReaderRoute<T>> {
  T? _value;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final generation = ++_generation;
    setStateIfMounted(() {
      _value = null;
      _error = null;
    });
    unawaited(() async {
      try {
        final value = await widget.load();
        if (!mounted || generation != _generation) return;
        setState(() => _value = value);
      } on Object catch (error) {
        if (!mounted || generation != _generation) return;
        setState(() => _error = error);
      }
    }());
  }

  void setStateIfMounted(VoidCallback update) {
    if (mounted) {
      setState(update);
    } else {
      update();
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    if (value != null) {
      return widget.builder(context, value);
    }
    final error = _error;
    return Scaffold(
      key: deferredReaderRouteKey,
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Center(
              child: error == null
                  ? const CircularProgressIndicator(
                      key: deferredReaderLoadingKey,
                    )
                  : Column(
                      key: deferredReaderErrorKey,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            '章节加载失败：$error',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        FilledButton.icon(
                          key: deferredReaderRetryKey,
                          onPressed: _start,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                      ],
                    ),
            ),
            Align(
              alignment: Alignment.topLeft,
              child: BackButton(
                color: Colors.white,
                onPressed: () => Navigator.maybePop(context),
              ),
            ),
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 14, left: 56, right: 56),
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

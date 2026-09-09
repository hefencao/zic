import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// User-visible technical failures must not force the user to transcribe the
/// diagnostic text. The owning feature may also record a Trace event, but this
/// presentation helper always preserves the exact displayed message on the
/// clipboard path.
Future<void> copyDiagnosticText(String message) =>
    Clipboard.setData(ClipboardData(text: message));

SnackBar copyableDiagnosticSnackBar(String message) => SnackBar(
  content: Text(message),
  action: SnackBarAction(
    label: '复制',
    onPressed: () => unawaited(copyDiagnosticText(message)),
  ),
);

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/diagnostic_error_ui.dart';

void main() {
  test('technical error snackbar always exposes a copy action', () {
    final snackBar = copyableDiagnosticSnackBar('failure details');

    expect((snackBar.content as Text).data, 'failure details');
    expect(snackBar.action, isNotNull);
    expect(snackBar.action!.label, '复制');
  });
}

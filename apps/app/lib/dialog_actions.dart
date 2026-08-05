import 'package:flutter/material.dart';

/// Standard action row for modal panels.
///
/// Closing a panel is always represented by the lower-left X. Confirming or
/// applying an operation stays on the lower-right side of the row.
final class AppDialogActions extends StatelessWidget {
  const AppDialogActions({
    required this.onClose,
    required this.actions,
    super.key,
  });

  final VoidCallback onClose;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          IconButton(
            tooltip: '关闭',
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
          const Spacer(),
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: actions,
            ),
          ),
        ],
      ),
    );
  }
}

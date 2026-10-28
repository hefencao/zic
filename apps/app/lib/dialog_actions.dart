import 'package:flutter/material.dart';

/// Standard action row for modal panels.
///
/// Closing a panel is always represented by the lower-left X. Confirming or
/// applying an operation stays on the lower-right side of the row.
/// Button geometry is local to the panel; actions wrap across its remaining width.
final class AppDialogActions extends StatelessWidget {
  const AppDialogActions({
    required this.onClose,
    required this.actions,
    super.key,
  });

  final VoidCallback? onClose;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    );
    const buttonStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(48, 40)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
      shape: WidgetStatePropertyAll(shape),
      tapTargetSize: MaterialTapTargetSize.padded,
    );
    return Theme(
      data: theme.copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: buttonStyle.merge(theme.filledButtonTheme.style)),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: buttonStyle.merge(theme.outlinedButtonTheme.style)),
        textButtonTheme: TextButtonThemeData(
          style: buttonStyle.merge(theme.textButtonTheme.style)),
        iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(
            minimumSize: const Size.square(40),
            padding: const EdgeInsets.all(10),
            iconSize: 20,
            shape: shape,
            tapTargetSize: MaterialTapTargetSize.padded,
            foregroundColor: colors.onSurfaceVariant,
            backgroundColor: colors.surfaceContainerHighest,
            disabledForegroundColor: colors.onSurface.withValues(alpha: .38),
            disabledBackgroundColor: Colors.transparent,
          ).merge(theme.iconButtonTheme.style)),
      ),
      child: SizedBox(
        width: double.infinity,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            IconButton(
              tooltip: '关闭',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: actions,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

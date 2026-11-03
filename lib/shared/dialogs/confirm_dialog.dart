import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';

/// Confirmation dialog for destructive or irreversible actions.
///
/// Returns `true` only when the user explicitly confirms; dismissing the dialog
/// returns `false`, so callers never act on an accidental tap outside.
Future<bool> showConfirmDialog(
  BuildContext context, {
  String? title,
  String? message,
  String? confirmLabel,
  bool destructive = false,
}) async {
  final l10n = AppLocalizations.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title ?? l10n.confirmDeleteTitle),
      content: Text(message ?? l10n.confirmDeleteMessage),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).colorScheme.error,
                  foregroundColor: Theme.of(dialogContext).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel ?? l10n.actionConfirm),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Simple prompt for a single text value, used for names and reasons.
Future<String?> showTextPromptDialog(
  BuildContext context, {
  required String title,
  String? initialValue,
  String? hintText,
  String? confirmLabel,
  int maxLines = 1,
}) async {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController(text: initialValue);
  final value = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: maxLines,
        decoration: InputDecoration(hintText: hintText),
        onSubmitted: (text) => Navigator.of(dialogContext).pop(text.trim()),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: Text(confirmLabel ?? l10n.actionSave),
        ),
      ],
    ),
  );
  controller.dispose();
  return (value == null || value.isEmpty) ? null : value;
}

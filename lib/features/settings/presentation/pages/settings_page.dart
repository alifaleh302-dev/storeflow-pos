import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Settings feature page.
///
/// Scheduled for Phase 1/9. Until then this page reports its status honestly
/// rather than showing placeholder data.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Settings',
      plannedPhase: 'Phase 1/9',
      summary: 'Store details, language, theme, printing, security and backup entry points.',
    );
  }
}

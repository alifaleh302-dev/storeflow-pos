import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Backup & restore feature page.
///
/// Scheduled for Phase 9. Until then this page reports its status honestly
/// rather than showing placeholder data.
class BackupPage extends StatelessWidget {
  const BackupPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Backup & restore',
      plannedPhase: 'Phase 9',
      summary: 'Encrypted .sfp snapshots, manifest validation, safe restore.',
    );
  }
}

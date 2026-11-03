import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../l10n/generated/app_localizations.dart';

/// Shown by feature pages whose module is scheduled for a later development
/// phase.
///
/// This widget exists so that navigation, theming, localisation and database
/// wiring can be verified end to end before every feature is written. It states
/// plainly that the module is not implemented yet and names the phase that will
/// implement it. It deliberately offers no controls that appear to do work, and
/// it is never presented as a finished feature.
class PendingModuleView extends StatelessWidget {
  const PendingModuleView({
    required this.moduleName,
    required this.plannedPhase,
    this.summary,
    super.key,
  });

  /// Human-readable module name, for example "Purchases".
  final String moduleName;

  /// The roadmap phase that will implement this module.
  final String plannedPhase;

  /// One-line description of what the module will do.
  final String? summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.construction_outlined, size: 56, color: scheme.tertiary),
              const SizedBox(height: 16),
              Text(
                moduleName,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'This module is not implemented yet. It is scheduled for $plannedPhase.',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              if (summary != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  summary!,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Foundation status',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Schema version: $kSchemaVersion. '
                        'Navigation, localisation and the database are wired and '
                        'covered by tests. Feature data is not yet stored by this screen.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Convenience scaffold for a not-yet-implemented feature page.
class PendingModulePage extends StatelessWidget {
  const PendingModulePage({
    required this.title,
    required this.plannedPhase,
    this.summary,
    super.key,
  });

  final String title;
  final String plannedPhase;
  final String? summary;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: PendingModuleView(
        moduleName: title,
        plannedPhase: plannedPhase,
        summary: summary,
      ),
    );
  }
}

/// Localisation helper kept here so pages that only need a title do not have to
/// import the generated localisations directly.
String appTitleOf(BuildContext context) => AppLocalizations.of(context).appTitle;

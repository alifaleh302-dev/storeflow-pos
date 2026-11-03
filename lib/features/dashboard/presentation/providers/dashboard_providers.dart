import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/app_providers.dart';
import '../../data/dashboard_repository.dart';
import '../../domain/entities/dashboard_period.dart';
import '../../domain/entities/dashboard_snapshot.dart';

final dashboardRepositoryProvider = Provider<DashboardRepository>(
  (ref) => DashboardRepository(ref.watch(databaseProvider)),
);

/// The selected dashboard period preset.
class DashboardPeriodController extends Notifier<PeriodPreset> {
  @override
  PeriodPreset build() => PeriodPreset.today;

  void select(PeriodPreset preset) => state = preset;
}

final dashboardPeriodProvider =
    NotifierProvider<DashboardPeriodController, PeriodPreset>(
  DashboardPeriodController.new,
);

/// A custom range chosen by the user, used when the preset is
/// [PeriodPreset.custom]. Riverpod 3 removed `StateProvider`, so this is a
/// small Notifier with an explicit setter.
class CustomRangeController extends Notifier<DateRange?> {
  @override
  DateRange? build() => null;

  void set(DateRange range) => state = range;
}

final customRangeProvider =
    NotifierProvider<CustomRangeController, DateRange?>(
  CustomRangeController.new,
);

/// The resolved range for the current selection.
final resolvedRangeProvider = Provider<DateRange>((ref) {
  final preset = ref.watch(dashboardPeriodProvider);
  final custom = ref.watch(customRangeProvider);
  return preset.resolve(DateTime.now(), custom: custom);
});

/// Live dashboard figures.
///
/// Watching the resolved range means changing the period re-runs the queries
/// automatically. The database is opened in WAL mode, so these reads do not
/// block a concurrent checkout.
final dashboardSnapshotProvider = FutureProvider<DashboardSnapshot>((ref) {
  final range = ref.watch(resolvedRangeProvider);
  return ref.watch(dashboardRepositoryProvider).load(range);
});

import '../../../../core/utils/timestamps.dart';

/// A resolved reporting window with inclusive start and exclusive end.
///
/// Using an exclusive end bound avoids the classic bug where an invoice created
/// at 23:59:59.999 is excluded from "today" because the end was `23:59:59`.
class DateRange {
  const DateRange({required this.start, required this.endExclusive});

  /// Inclusive lower bound in UTC.
  final DateTime start;

  /// Exclusive upper bound in UTC.
  final DateTime endExclusive;

  /// A single calendar day in local time, converted to UTC bounds.
  ///
  /// The conversion happens against local midnight so that "today" matches the
  /// user's wall clock, not UTC midnight.
  factory DateRange.day(DateTime localDay) {
    final localStart = DateTime(localDay.year, localDay.month, localDay.day);
    final localEnd = localStart.add(const Duration(days: 1));
    return DateRange(
      start: localStart.toUtc(),
      endExclusive: localEnd.toUtc(),
    );
  }

  /// The seven days ending on [localDay], starting at local midnight.
  factory DateRange.week(DateTime localDay) {
    final localStart = DateTime(localDay.year, localDay.month, localDay.day)
        .subtract(const Duration(days: 6));
    final localEnd =
        DateTime(localDay.year, localDay.month, localDay.day)
            .add(const Duration(days: 1));
    return DateRange(
      start: localStart.toUtc(),
      endExclusive: localEnd.toUtc(),
    );
  }

  /// The calendar month containing [localDay].
  factory DateRange.month(DateTime localDay) {
    final localStart = DateTime(localDay.year, localDay.month);
    final localEnd = DateTime(localDay.year, localDay.month + 1);
    return DateRange(
      start: localStart.toUtc(),
      endExclusive: localEnd.toUtc(),
    );
  }

  /// An arbitrary local range; [endInclusive] is made exclusive internally.
  factory DateRange.custom(DateTime fromLocal, DateTime toInclusiveLocal) {
    final localStart = DateTime(fromLocal.year, fromLocal.month, fromLocal.day);
    final localEnd =
        DateTime(toInclusiveLocal.year, toInclusiveLocal.month, toInclusiveLocal.day)
            .add(const Duration(days: 1));
    return DateRange(
      start: localStart.toUtc(),
      endExclusive: localEnd.toUtc(),
    );
  }

  /// The range in the storage format, ready to bind into a SQL comparison.
  String get startStorage => toStorageTimestamp(start);
  String get endStorage => toStorageTimestamp(endExclusive);

  /// Number of whole days covered, used to size the sales chart.
  int get dayCount => endExclusive.difference(start).inDays;

  @override
  String toString() => '$startStorage..$endStorage';
}

/// The preset periods offered by the dashboard and report filters.
enum PeriodPreset {
  today,
  yesterday,
  thisWeek,
  thisMonth,
  custom;

  /// Resolves this preset against [now] in local time.
  DateRange resolve(DateTime now, {DateRange? custom}) {
    return switch (this) {
      PeriodPreset.today => DateRange.day(now),
      PeriodPreset.yesterday =>
        DateRange.day(now.subtract(const Duration(days: 1))),
      PeriodPreset.thisWeek => DateRange.week(now),
      PeriodPreset.thisMonth => DateRange.month(now),
      PeriodPreset.custom =>
        custom ?? DateRange.day(now),
    };
  }
}

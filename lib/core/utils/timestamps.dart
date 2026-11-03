/// UTC timestamp helpers.
///
/// Every timestamp is persisted as an ISO-8601 string in UTC. Local time is
/// applied only for display, so the same database renders correctly in any
/// timezone and no daylight-saving ambiguity can corrupt ordering.
library;

/// Converts a [DateTime] to the canonical storage representation.
///
/// Returns e.g. `2026-11-03T18:26:31.123Z`. A local [DateTime] is converted to
/// UTC first; a UTC one is kept as-is.
String toStorageTimestamp(DateTime value) {
  final utc = value.isUtc ? value : value.toUtc();
  return '${utc.toIso8601String().split('.').first}.${_millis(utc)}Z';
}

String _millis(DateTime utc) =>
    utc.millisecond.toString().padLeft(3, '0');

/// Parses a stored timestamp back into a UTC [DateTime].
DateTime fromStorageTimestamp(String value) => DateTime.parse(value).toUtc();

/// The current instant in storage form.
String nowStorageTimestamp() => toStorageTimestamp(DateTime.now());

/// The current instant as UTC.
DateTime nowUtc() => DateTime.now().toUtc();

/// Start of the given [date] in UTC, used for date-range report filters.
DateTime startOfDayUtc(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

/// Start of the day *after* [date] in UTC, for exclusive upper bounds.
DateTime endOfDayExclusiveUtc(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day).add(const Duration(days: 1));

/// Formats a stored timestamp for display in the local timezone.
String formatLocalTimestamp(
  String storageValue, {
  bool withSeconds = true,
}) {
  final local = fromStorageTimestamp(storageValue).toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final mo = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final h = local.hour.toString().padLeft(2, '0');
  final mi = local.minute.toString().padLeft(2, '0');
  if (!withSeconds) return '$y-$mo-$d $h:$mi';
  final s = local.second.toString().padLeft(2, '0');
  return '$y-$mo-$d $h:$mi:$s';
}

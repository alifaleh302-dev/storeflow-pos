import '../../../../core/utils/csv.dart';

/// One column of a report.
class ReportColumn {
  const ReportColumn({
    required this.key,
    required this.label,
    this.numeric = false,
  });

  final String key;
  final String label;

  /// Numeric columns are right-aligned in the interface and are not quoted in
  /// the CSV unless they contain a separator.
  final bool numeric;
}

/// One row of a report, keyed by column.
class ReportRow {
  const ReportRow(this.cells);

  final Map<String, String> cells;

  String operator [](String key) => cells[key] ?? '';
}

/// A tabular report with a total row and CSV export.
///
/// A report is data, not a widget. Keeping it separate means the same figures can
/// be shown in a table, exported to a file, and asserted against a known dataset
/// in a test, all without going through the interface.
class ReportTable {
  const ReportTable({
    required this.title,
    required this.columns,
    required this.rows,
    this.totals,
    this.currencyCode,
    this.note,
  });

  final String title;
  final List<ReportColumn> columns;
  final List<ReportRow> rows;

  /// A final row of totals, keyed the same way as the data rows.
  final ReportRow? totals;

  final String? currencyCode;

  /// A short explanation of what the figures mean, shown under the title.
  final String? note;

  bool get isEmpty => rows.isEmpty;

  /// Serialises the report as RFC 4180 CSV.
  ///
  /// The header is the column labels, not the keys, because a spreadsheet reader
  /// sees the labels. The total row is appended with its first cell labelled
  /// `TOTAL`, so an exported report is self-explanatory when opened on its own.
  String toCsv() {
    final header = <String>[for (final column in columns) column.label];
    final lines = <List<String>>[header];
    for (final row in rows) {
      lines.add(<String>[for (final column in columns) row[column.key]]);
    }
    final totalRow = totals;
    if (totalRow != null) {
      lines.add(<String>[
        for (var i = 0; i < columns.length; i++)
          i == 0 ? 'TOTAL' : totalRow[columns[i].key],
      ]);
    }
    return Csv.encode(lines);
  }

  /// A file name for an export, built from the title and the period.
  String fileName(String periodLabel) {
    final safeTitle = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return '${safeTitle}_$periodLabel.csv';
  }
}

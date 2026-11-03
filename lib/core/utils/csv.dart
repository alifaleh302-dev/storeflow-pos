/// RFC 4180 CSV encoding and decoding.
///
/// Written rather than taken from a package because the product import path is
/// a data-integrity boundary: a malformed file must produce a precise, per-row
/// error rather than silently dropping or mangling rows.
library;

/// A CSV parse failure with the offending row and column.
class CsvFormatException implements Exception {
  const CsvFormatException(this.message, {this.line, this.column});

  final String message;

  /// One-based line number, when known.
  final int? line;

  /// One-based column number, when known.
  final int? column;

  @override
  String toString() {
    final position = <String>[
      if (line != null) 'line $line',
      if (column != null) 'column $column',
    ].join(', ');
    return position.isEmpty
        ? 'CsvFormatException: $message'
        : 'CsvFormatException: $message ($position)';
  }
}

/// Parses and serialises CSV text.
abstract final class Csv {
  /// Parses [input] into rows of fields.
  ///
  /// Handles quoted fields, embedded commas, embedded newlines and doubled
  /// quotes (`""` inside a quoted field). A UTF-8 byte order mark at the start
  /// is stripped, because spreadsheet exports routinely include one and it would
  /// otherwise corrupt the first header name.
  static List<List<String>> parse(String input) {
    final text = _stripBom(input);
    final rows = <List<String>>[];
    var field = StringBuffer();
    var row = <String>[];
    var inQuotes = false;
    var line = 1;
    var column = 1;
    var i = 0;

    while (i < text.length) {
      final char = text[i];

      if (inQuotes) {
        if (char == '"') {
          final isEscapedQuote = i + 1 < text.length && text[i + 1] == '"';
          if (isEscapedQuote) {
            field.write('"');
            i += 2;
            column += 2;
            continue;
          }
          inQuotes = false;
          i++;
          column++;
          continue;
        }
        if (char == '\n') line++;
        if (char == '\n') column = 1;
        field.write(char);
        i++;
        if (char != '\n') column++;
        continue;
      }

      if (char == '"') {
        if (field.isNotEmpty) {
          // A quote may only open a field. `a"b` is malformed.
          throw CsvFormatException(
            'Unexpected quote inside an unquoted field',
            line: line,
            column: column,
          );
        }
        inQuotes = true;
        i++;
        column++;
        continue;
      }

      if (char == ',') {
        row.add(field.toString());
        field = StringBuffer();
        i++;
        column++;
        continue;
      }

      if (char == '\r') {
        // Accept CRLF and a bare CR as a line break.
        row.add(field.toString());
        field = StringBuffer();
        rows.add(row);
        row = <String>[];
        i++;
        if (i < text.length && text[i] == '\n') i++;
        line++;
        column = 1;
        continue;
      }

      if (char == '\n') {
        row.add(field.toString());
        field = StringBuffer();
        rows.add(row);
        row = <String>[];
        i++;
        line++;
        column = 1;
        continue;
      }

      field.write(char);
      i++;
      column++;
    }

    if (inQuotes) {
      throw CsvFormatException(
        'Unterminated quoted field',
        line: line,
        column: column,
      );
    }

    // A trailing newline produces no extra row; a trailing field does.
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }

    return rows;
  }

  /// Encodes [rows] as CSV text with CRLF line endings, per RFC 4180.
  static String encode(List<List<String>> rows) {
    final buffer = StringBuffer();
    for (final row in rows) {
      buffer.write(row.map(_escapeField).join(','));
      buffer.write('\r\n');
    }
    return buffer.toString();
  }

  static String _escapeField(String value) {
    final needsQuoting = value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r');
    if (!needsQuoting) return value;
    return '"${value.replaceAll('"', '""')}"';
  }

  static String _stripBom(String input) =>
      input.isNotEmpty && input.codeUnitAt(0) == 0xFEFF ? input.substring(1) : input;
}

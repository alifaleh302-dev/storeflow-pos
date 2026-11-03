/// Offset pagination primitives.
///
/// Product catalogs, movement histories and report tables can hold hundreds of
/// thousands of rows. Nothing in the application loads a full table into memory;
/// every list query takes a [PageRequest] and returns a [Page].
library;

/// A bounded window over a result set.
class PageRequest {
  const PageRequest({this.offset = 0, this.limit = defaultLimit})
      : assert(offset >= 0, 'offset cannot be negative'),
        assert(limit > 0, 'limit must be positive');

  /// Default page size. Chosen to fill a desktop table without a scroll, while
  /// staying small enough that a phone never stalls rendering a page.
  static const int defaultLimit = 50;

  /// Hard ceiling. A caller asking for more than this is almost certainly a bug,
  /// and honouring it would defeat the point of paging.
  static const int maxLimit = 500;

  final int offset;
  final int limit;

  /// The effective limit, clamped to [maxLimit].
  int get effectiveLimit => limit > maxLimit ? maxLimit : limit;

  /// The window following this one.
  PageRequest next() => PageRequest(offset: offset + effectiveLimit, limit: limit);

  /// The window preceding this one, or `null` at the start.
  PageRequest? previous() {
    if (offset == 0) return null;
    final newOffset = offset - effectiveLimit;
    return PageRequest(offset: newOffset < 0 ? 0 : newOffset, limit: limit);
  }

  /// The zero-based index of the first row, for "showing 51–100" labels.
  int get firstRowNumber => offset + 1;

  @override
  bool operator ==(Object other) =>
      other is PageRequest && other.offset == offset && other.limit == limit;

  @override
  int get hashCode => Object.hash(offset, limit);

  @override
  String toString() => 'PageRequest(offset: $offset, limit: $limit)';
}

/// One page of results plus the total size of the underlying set.
///
/// [totalCount] is carried so a UI can show "51–100 of 1,240" and size a
/// paginator without a second round trip.
class Page<T> {
  const Page({
    required this.items,
    required this.totalCount,
    required this.request,
  });

  /// An empty page, used before the first query resolves.
  const Page.empty()
      : items = const [],
        totalCount = 0,
        request = const PageRequest();

  final List<T> items;
  final int totalCount;
  final PageRequest request;

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  /// Whether rows exist after this page.
  bool get hasMore => request.offset + items.length < totalCount;

  /// Whether rows exist before this page.
  bool get hasPrevious => request.offset > 0;

  /// One-based index of the last row shown, or 0 when empty.
  int get lastRowNumber => items.isEmpty ? 0 : request.offset + items.length;

  /// Maps the items while preserving the paging metadata.
  Page<R> map<R>(R Function(T item) transform) => Page<R>(
        items: items.map(transform).toList(),
        totalCount: totalCount,
        request: request,
      );
}

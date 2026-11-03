import 'package:drift/drift.dart';

import '../../../../core/errors/failures.dart';
import '../../../../core/utils/pagination.dart';
import '../../../../core/utils/timestamps.dart';
import '../../../../infrastructure/database/app_database.dart';
import '../../domain/entities/product.dart';

/// Reads and writes the product catalog.
///
/// Every listing method is paged and every search is backed by an index, so a
/// shop with a hundred thousand products never loads the catalog into memory.
/// Uniqueness violations are translated into [ValidationFailure] so the UI can
/// point at the offending field instead of surfacing a raw SQLite error.
class ProductRepository {
  ProductRepository(this._db);

  final AppDatabase _db;

  /// One page of products matching [filter], ordered by name.
  Future<Page<Product>> search({
    ProductFilter filter = const ProductFilter(),
    PageRequest request = const PageRequest(),
  }) async {
    final where = _buildWhere(filter);

    final rows = await (_db.select(_db.products)
          ..where((t) => where)
          ..orderBy(<OrderClauseGenerator<$ProductsTable>>[
            (t) => OrderingTerm(expression: t.name),
            (t) => OrderingTerm(expression: t.id),
          ])
          ..limit(request.effectiveLimit, offset: request.offset))
        .get();

    final total = await _countProducts(filter);

    return Page<Product>(
      items: await _hydrate(rows),
      totalCount: total,
      request: request,
    );
  }

  /// A single product with its barcodes, names and stock resolved.
  Future<Product?> findById(int id) async {
    final row = await (_db.select(_db.products)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    final hydrated = await _hydrate(<ProductRow>[row]);
    return hydrated.single;
  }

  /// Resolves a barcode to its product, for a scan or a typed code.
  ///
  /// Returns null when the code is unknown, so the POS can offer to create a
  /// product instead of failing.
  Future<Product?> findByBarcode(String barcode) async {
    final trimmed = barcode.trim();
    if (trimmed.isEmpty) return null;
    final link = await (_db.select(_db.productBarcodes)
          ..where((t) => t.barcode.equals(trimmed)))
        .getSingleOrNull();
    if (link == null) return null;
    return findById(link.productId);
  }

  /// Resolves a SKU to its product.
  Future<Product?> findBySku(String sku) async {
    final trimmed = sku.trim();
    if (trimmed.isEmpty) return null;
    final row = await (_db.select(_db.products)
          ..where((t) => t.sku.equals(trimmed)))
        .getSingleOrNull();
    if (row == null) return null;
    final hydrated = await _hydrate(<ProductRow>[row]);
    return hydrated.single;
  }

  /// Creates a product and returns its identifier.
  ///
  /// The product and its barcodes are written in one transaction, so a rejected
  /// barcode cannot leave a product with no way to be scanned.
  Future<int> create({
    required String name,
    String? sku,
    int? categoryId,
    int? unitId,
    int purchaseCostMinor = 0,
    int sellingPriceMinor = 0,
    int minimumStockScaled = 0,
    String? description,
    String? imagePath,
    List<String> barcodes = const <String>[],
  }) async {
    final cleanName = _validateName(name);
    final cleanSku = _normaliseOptional(sku);
    final cleanBarcodes = _validateBarcodes(barcodes);
    _validateAmounts(purchaseCostMinor, sellingPriceMinor, minimumStockScaled);

    return _db.transaction(() async {
      await _assertSkuAvailable(cleanSku);
      await _assertBarcodesAvailable(cleanBarcodes);

      final timestamp = nowStorageTimestamp();
      final id = await _db.into(_db.products).insert(
            ProductsCompanion.insert(
              name: cleanName,
              sku: Value(cleanSku),
              categoryId: Value(categoryId),
              unitId: Value(unitId),
              purchaseCost: Value(purchaseCostMinor),
              sellingPrice: Value(sellingPriceMinor),
              minimumStock: Value(minimumStockScaled),
              description: Value(_normaliseOptional(description)),
              imagePath: Value(_normaliseOptional(imagePath)),
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );

      await _insertBarcodes(id, cleanBarcodes, timestamp);
      return id;
    });
  }

  /// Updates a product in place. Barcodes are replaced by [barcodes] when given.
  Future<void> update({
    required int id,
    required String name,
    String? sku,
    int? categoryId,
    int? unitId,
    int purchaseCostMinor = 0,
    int sellingPriceMinor = 0,
    int minimumStockScaled = 0,
    String? description,
    String? imagePath,
    List<String>? barcodes,
    bool? isActive,
  }) async {
    final cleanName = _validateName(name);
    final cleanSku = _normaliseOptional(sku);
    final cleanBarcodes = barcodes == null ? null : _validateBarcodes(barcodes);
    _validateAmounts(purchaseCostMinor, sellingPriceMinor, minimumStockScaled);

    await _db.transaction(() async {
      final existing = await (_db.select(_db.products)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (existing == null) {
        throw NotFoundFailure(
          'Product not found',
          details: <String, Object?>{'productId': id},
        );
      }

      await _assertSkuAvailable(cleanSku, excludingProductId: id);
      if (cleanBarcodes != null) {
        await _assertBarcodesAvailable(cleanBarcodes, excludingProductId: id);
      }

      await (_db.update(_db.products)..where((t) => t.id.equals(id))).write(
        ProductsCompanion(
          name: Value(cleanName),
          sku: Value(cleanSku),
          categoryId: Value(categoryId),
          unitId: Value(unitId),
          purchaseCost: Value(purchaseCostMinor),
          sellingPrice: Value(sellingPriceMinor),
          minimumStock: Value(minimumStockScaled),
          description: Value(_normaliseOptional(description)),
          imagePath: Value(_normaliseOptional(imagePath)),
          isActive: isActive == null ? const Value.absent() : Value(isActive),
          updatedAt: Value(nowStorageTimestamp()),
        ),
      );

      if (cleanBarcodes != null) {
        await (_db.delete(_db.productBarcodes)
              ..where((t) => t.productId.equals(id)))
            .go();
        await _insertBarcodes(id, cleanBarcodes, nowStorageTimestamp());
      }
    });
  }

  /// Archives a product.
  ///
  /// Archiving is the only removal the application offers. A product referenced
  /// by a posted invoice or a stock movement cannot be deleted at all, because
  /// the schema's `restrict` foreign key refuses it, so offering deletion would
  /// be a promise the database would break. Archiving keeps the history intact
  /// and removes the product from the active catalog.
  Future<void> archive(int id) => _setActive(id, false);

  /// Restores an archived product to the active catalog.
  Future<void> restore(int id) => _setActive(id, true);

  Future<void> _setActive(int id, bool isActive) async {
    final updated = await (_db.update(_db.products)
          ..where((t) => t.id.equals(id)))
        .write(
      ProductsCompanion(
        isActive: Value(isActive),
        updatedAt: Value(nowStorageTimestamp()),
      ),
    );
    if (updated == 0) {
      throw NotFoundFailure(
        'Product not found',
        details: <String, Object?>{'productId': id},
      );
    }
  }

  /// Whether a product is referenced by any posted document.
  ///
  /// Lets the UI explain why a product cannot be removed instead of presenting
  /// an arbitrary failure. Archiving is still preferred when this is false.
  Future<bool> isReferenced(int id) async {
    final row = await _db.customSelect(
      '''
      SELECT EXISTS (
        SELECT 1 FROM sale_items WHERE product_id = :id
        UNION ALL
        SELECT 1 FROM purchase_items WHERE product_id = :id
        UNION ALL
        SELECT 1 FROM inventory_movements WHERE product_id = :id
      ) AS referenced
      ''',
      variables: <Variable<int>>[Variable<int>(id)],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.saleItems,
        _db.purchaseItems,
        _db.inventoryMovements,
      },
    ).getSingle();
    return row.read<int>('referenced') == 1;
  }

  /// Counts products matching a filter without loading them.
  Future<int> count({ProductFilter filter = const ProductFilter()}) =>
      _countProducts(filter);

  /// Every product as CSV rows, for export.
  ///
  /// Walks the catalog in pages rather than building one enormous list, so
  /// exporting a large catalog stays within the same memory budget as browsing it.
  Future<List<List<String>>> exportRows() async {
    const batchSize = PageRequest.maxLimit;
    final rows = <List<String>>[
      <String>[
        'sku',
        'name',
        'category',
        'unit',
        'purchase_cost',
        'selling_price',
        'minimum_stock',
        'stock',
        'barcodes',
        'description',
        'active',
      ],
    ];

    var offset = 0;
    while (true) {
      final page = await search(
        filter: const ProductFilter(includeArchived: true),
        request: PageRequest(offset: offset, limit: batchSize),
      );
      for (final product in page.items) {
        rows.add(<String>[
          product.sku ?? '',
          product.name,
          product.categoryName ?? '',
          product.unitName ?? '',
          _minorToDecimal(product.purchaseCostMinor ?? 0),
          _minorToDecimal(product.sellingPriceMinor ?? 0),
          _scaledToDecimal(product.minimumStockScaled),
          _scaledToDecimal(product.stockQuantityScaled),
          product.barcodes.join('|'),
          product.description ?? '',
          product.isActive ? '1' : '0',
        ]);
      }
      if (!page.hasMore) break;
      offset += page.items.length;
    }
    return rows;
  }

  /// Imports products from CSV rows.
  ///
  /// Returns a per-row outcome rather than throwing on the first problem, so a
  /// file with three bad rows still imports the other nine hundred and the user
  /// gets a precise list of what to fix. The whole import runs in one
  /// transaction, so an abort leaves nothing behind.
  Future<ImportReport> importRows(
    List<List<String>> rows, {
    bool updateExisting = true,
  }) async {
    if (rows.isEmpty) {
      throw const ValidationFailure('The file is empty', field: 'file');
    }

    final header = rows.first.map((cell) => cell.trim().toLowerCase()).toList();
    final nameIndex = header.indexOf('name');
    if (nameIndex < 0) {
      throw const ValidationFailure(
        'The file needs a "name" column',
        field: 'file',
      );
    }
    final skuIndex = header.indexOf('sku');
    final categoryIndex = header.indexOf('category');
    final unitIndex = header.indexOf('unit');
    final costIndex = header.indexOf('purchase_cost');
    final priceIndex = header.indexOf('selling_price');
    final minStockIndex = header.indexOf('minimum_stock');
    final barcodesIndex = header.indexOf('barcodes');
    final descriptionIndex = header.indexOf('description');
    final activeIndex = header.indexOf('active');

    final categories = await _categoryIdsByName();
    final units = await _unitIdsByCodeOrName();

    final report = ImportReport();
    final pending = <_PendingImport>[];

    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      final lineNumber = i + 1;
      if (row.every((cell) => cell.trim().isEmpty)) continue;

      String cell(int index) =>
          index >= 0 && index < row.length ? row[index].trim() : '';

      final name = cell(nameIndex);
      if (name.isEmpty) {
        report.rejected(lineNumber, 'Missing product name');
        continue;
      }

      final cost = _parseMinor(cell(costIndex));
      if (cost == null) {
        report.rejected(lineNumber, 'Invalid purchase_cost "${cell(costIndex)}"');
        continue;
      }
      final price = _parseMinor(cell(priceIndex));
      if (price == null) {
        report.rejected(lineNumber, 'Invalid selling_price "${cell(priceIndex)}"');
        continue;
      }
      final minStock = _parseScaled(cell(minStockIndex));
      if (minStock == null) {
        report.rejected(lineNumber, 'Invalid minimum_stock "${cell(minStockIndex)}"');
        continue;
      }

      final categoryName = cell(categoryIndex);
      final unitName = cell(unitIndex);

      pending.add(
        _PendingImport(
          lineNumber: lineNumber,
          name: name,
          sku: _normaliseOptional(cell(skuIndex)),
          categoryId:
              categoryName.isEmpty ? null : categories[categoryName.toLowerCase()],
          unitId: unitName.isEmpty ? null : units[unitName.toLowerCase()],
          purchaseCostMinor: cost,
          sellingPriceMinor: price,
          minimumStockScaled: minStock,
          barcodes: cell(barcodesIndex)
              .split('|')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList(),
          description: _normaliseOptional(cell(descriptionIndex)),
          isActive: activeIndex < 0 || cell(activeIndex) != '0',
        ),
      );
    }

    await _db.transaction(() async {
      for (final item in pending) {
        try {
          final existing = item.sku == null ? null : await findBySku(item.sku!);
          if (existing != null) {
            if (!updateExisting) {
              report.rejected(item.lineNumber, 'SKU "${item.sku}" already exists');
              continue;
            }
            await update(
              id: existing.id,
              name: item.name,
              sku: item.sku,
              categoryId: item.categoryId,
              unitId: item.unitId,
              purchaseCostMinor: item.purchaseCostMinor,
              sellingPriceMinor: item.sellingPriceMinor,
              minimumStockScaled: item.minimumStockScaled,
              description: item.description,
              barcodes: item.barcodes,
              isActive: item.isActive,
            );
            report.updated(item.lineNumber, item.name);
            continue;
          }
          await create(
            name: item.name,
            sku: item.sku,
            categoryId: item.categoryId,
            unitId: item.unitId,
            purchaseCostMinor: item.purchaseCostMinor,
            sellingPriceMinor: item.sellingPriceMinor,
            minimumStockScaled: item.minimumStockScaled,
            description: item.description,
            barcodes: item.barcodes,
          );
          report.created(item.lineNumber, item.name);
        } on AppFailure catch (failure) {
          report.rejected(item.lineNumber, '${item.name}: ${failure.message}');
        }
      }
    });

    return report;
  }

  /// Products at or below their reorder threshold, most urgent first.
  ///
  /// A product with no stock row counts as zero on hand, which is below any
  /// positive threshold, so a never-received product is reported as low stock.
  Future<List<Product>> lowStock({int limit = 50}) async {
    final rows = await _db.customSelect(
      '''
      SELECT p.* FROM products p
      LEFT JOIN product_stock s ON s.product_id = p.id
      WHERE p.is_active = 1
        AND p.minimum_stock > 0
        AND COALESCE(s.quantity_scaled, 0) <= p.minimum_stock
      ORDER BY (COALESCE(s.quantity_scaled, 0) - p.minimum_stock) ASC, p.name
      LIMIT :limit
      ''',
      variables: <Variable<int>>[Variable<int>(limit)],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.products,
        _db.productStock,
      },
    ).get();
    return _hydrate(
      rows.map((row) => _db.products.map(row.data)).toList(growable: false),
    );
  }

  /// The most recently created products.
  Future<List<Product>> recentlyAdded({int limit = 10}) async {
    final rows = await (_db.select(_db.products)
          ..orderBy(<OrderClauseGenerator<$ProductsTable>>[
            (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .get();
    return _hydrate(rows);
  }

  // ---------------------------------------------------------------- internals

  Expression<bool> _buildWhere(ProductFilter filter) {
    Expression<bool> predicate = _db.products.id.isBiggerThanValue(0);

    if (!filter.includeArchived) {
      predicate = predicate & _db.products.isActive.equals(true);
    }
    if (filter.categoryId != null) {
      predicate = predicate & _db.products.categoryId.equals(filter.categoryId!);
    }
    if (filter.unitId != null) {
      predicate = predicate & _db.products.unitId.equals(filter.unitId!);
    }

    final term = filter.searchTerm?.trim();
    if (term != null && term.isNotEmpty) {
      final pattern = '%${_escapeLike(term)}%';
      // SQLite only treats `\` as an escape character when the LIKE clause says
      // so, so every comparison declares it. Without this, searching for "100%"
      // escapes the percent sign and then matches nothing at all.
      // Barcode matching runs as a correlated subquery rather than a join, so the
      // product rows are not duplicated when a product carries several barcodes.
      predicate = predicate &
          (_db.products.name.like(pattern, escapeChar: _likeEscape) |
              _db.products.sku.like(pattern, escapeChar: _likeEscape) |
              _db.products.id.isInQuery(
                _db.selectOnly(_db.productBarcodes)
                  ..addColumns(<Expression<Object>>[_db.productBarcodes.productId])
                  ..where(_db.productBarcodes.barcode
                      .like(pattern, escapeChar: _likeEscape)),
              ));
    }

    if (filter.lowStockOnly) {
      predicate = predicate &
          _db.products.minimumStock.isBiggerThanValue(0) &
          _db.products.id.isInQuery(
            _db.selectOnly(_db.productStock)
              ..addColumns(<Expression<Object>>[_db.productStock.productId])
              ..where(_db.productStock.quantityScaled
                  .isSmallerOrEqual(_db.products.minimumStock)),
          );
    }

    if (filter.onlyOutOfStock) {
      predicate = predicate &
          _db.products.id.isNotInQuery(
            _db.selectOnly(_db.productStock)
              ..addColumns(<Expression<Object>>[_db.productStock.productId])
              ..where(_db.productStock.quantityScaled.isBiggerThanValue(0)),
          );
    }

    return predicate;
  }

  Future<int> _countProducts(ProductFilter filter) async {
    final query = _db.selectOnly(_db.products)
      ..addColumns(<Expression<Object>>[countAll()])
      ..where(_buildWhere(filter));
    final row = await query.getSingle();
    return row.read(countAll()) ?? 0;
  }

  /// Loads category names, unit names, barcodes and stock for a set of rows.
  ///
  /// Four batched queries regardless of page size, rather than a join that would
  /// multiply rows or a per-row lookup that would be N+1.
  Future<List<Product>> _hydrate(List<ProductRow> rows) async {
    if (rows.isEmpty) return const <Product>[];

    final ids = <int>[for (final row in rows) row.id];
    final categoryIds = <int>{
      for (final row in rows)
        if (row.categoryId != null) row.categoryId!,
    }.toList(growable: false);
    final unitIds = <int>{
      for (final row in rows)
        if (row.unitId != null) row.unitId!,
    }.toList(growable: false);

    final categories = categoryIds.isEmpty
        ? const <CategoryRow>[]
        : await (_db.select(_db.categories)
              ..where((t) => t.id.isIn(categoryIds)))
            .get();
    final units = unitIds.isEmpty
        ? const <UnitRow>[]
        : await (_db.select(_db.units)..where((t) => t.id.isIn(unitIds))).get();
    final barcodes = await (_db.select(_db.productBarcodes)
          ..where((t) => t.productId.isIn(ids)))
        .get();
    final stocks = await (_db.select(_db.productStock)
          ..where((t) => t.productId.isIn(ids)))
        .get();

    final categoryById = <int, CategoryRow>{
      for (final category in categories) category.id: category,
    };
    final unitById = <int, UnitRow>{for (final unit in units) unit.id: unit};
    final stockByProduct = <int, ProductStockRow>{
      for (final stock in stocks) stock.productId: stock,
    };
    final barcodesByProduct = <int, List<String>>{};
    for (final barcode in barcodes) {
      barcodesByProduct
          .putIfAbsent(barcode.productId, () => <String>[])
          .add(barcode.barcode);
    }

    return rows.map((row) {
      final stock = stockByProduct[row.id];
      final unit = row.unitId == null ? null : unitById[row.unitId];
      return Product(
        id: row.id,
        name: row.name,
        sku: row.sku,
        categoryId: row.categoryId,
        categoryName:
            row.categoryId == null ? null : categoryById[row.categoryId]?.name,
        unitId: row.unitId,
        unitName: unit?.name,
        unitSymbol: unit?.symbol,
        purchaseCostMinor: row.purchaseCost,
        sellingPriceMinor: row.sellingPrice,
        minimumStockScaled: row.minimumStock,
        description: row.description,
        imagePath: row.imagePath,
        isActive: row.isActive,
        createdAtStorage: row.createdAt,
        updatedAtStorage: row.updatedAt,
        barcodes: barcodesByProduct[row.id] ?? const <String>[],
        stockQuantityScaled: stock?.quantityScaled ?? 0,
        averageCostMinor: stock?.averageCost ?? 0,
        hasStockRow: stock != null,
      );
    }).toList(growable: false);
  }

  Future<void> _insertBarcodes(
    int productId,
    List<String> barcodes,
    String timestamp,
  ) async {
    for (final barcode in barcodes) {
      await _db.into(_db.productBarcodes).insert(
            ProductBarcodesCompanion.insert(
              productId: productId,
              barcode: barcode,
              createdAt: timestamp,
            ),
          );
    }
  }

  Future<void> _assertSkuAvailable(String? sku, {int? excludingProductId}) async {
    if (sku == null) return;
    final query = _db.select(_db.products)..where((t) => t.sku.equals(sku));
    if (excludingProductId != null) {
      query.where((t) => t.id.equals(excludingProductId).not());
    }
    final existing = await query.getSingleOrNull();
    if (existing != null) {
      throw ValidationFailure(
        'SKU "$sku" is already used by another product',
        field: 'sku',
        details: <String, Object?>{'sku': sku, 'productId': existing.id},
      );
    }
  }

  Future<void> _assertBarcodesAvailable(
    List<String> barcodes, {
    int? excludingProductId,
  }) async {
    if (barcodes.isEmpty) return;
    final query = _db.select(_db.productBarcodes)
      ..where((t) => t.barcode.isIn(barcodes));
    if (excludingProductId != null) {
      query.where((t) => t.productId.equals(excludingProductId).not());
    }
    final clashes = await query.get();
    if (clashes.isNotEmpty) {
      throw ValidationFailure(
        'Barcode "${clashes.first.barcode}" is already assigned to another product',
        field: 'barcode',
        details: <String, Object?>{
          'barcode': clashes.first.barcode,
          'productId': clashes.first.productId,
        },
      );
    }
  }

  Future<Map<String, int>> _categoryIdsByName() async {
    final rows = await _db.select(_db.categories).get();
    return <String, int>{
      for (final row in rows) row.name.toLowerCase(): row.id,
    };
  }

  Future<Map<String, int>> _unitIdsByCodeOrName() async {
    final rows = await _db.select(_db.units).get();
    final map = <String, int>{};
    for (final row in rows) {
      map[row.code.toLowerCase()] = row.id;
      map[row.name.toLowerCase()] = row.id;
    }
    return map;
  }

  void _validateAmounts(int cost, int price, int minimumStock) {
    if (cost < 0 || price < 0) {
      throw const ValidationFailure('Prices cannot be negative', field: 'price');
    }
    if (minimumStock < 0) {
      throw const ValidationFailure(
        'Minimum stock cannot be negative',
        field: 'minimumStock',
      );
    }
  }

  String _validateName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ValidationFailure('Product name is required', field: 'name');
    }
    if (trimmed.length > 200) {
      throw const ValidationFailure(
        'Product name cannot exceed 200 characters',
        field: 'name',
      );
    }
    return trimmed;
  }

  List<String> _validateBarcodes(List<String> barcodes) {
    final cleaned = <String>[];
    final seen = <String>{};
    for (final raw in barcodes) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      if (!seen.add(value)) {
        throw ValidationFailure(
          'Barcode "$value" is listed twice',
          field: 'barcode',
        );
      }
      cleaned.add(value);
    }
    return cleaned;
  }

  String? _normaliseOptional(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// The escape character used by every LIKE clause in this repository.
  static const String _likeEscape = r'\';

  /// Escapes LIKE wildcards so a search for "50%" does not match every row.
  ///
  /// Paired with `escapeChar: _likeEscape` on the comparison, because SQLite does not
  /// interpret a backslash as an escape character unless the statement says so.
  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  static String _minorToDecimal(int minor) {
    final negative = minor < 0;
    final abs = minor.abs();
    return '${negative ? '-' : ''}${abs ~/ 100}'
        '.${(abs % 100).toString().padLeft(2, '0')}';
  }

  static String _scaledToDecimal(int scaled) {
    final negative = scaled < 0;
    final abs = scaled.abs();
    final whole = abs ~/ 1000;
    final fraction = (abs % 1000)
        .toString()
        .padLeft(3, '0')
        .replaceAll(RegExp(r'0+$'), '');
    return '${negative ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}';
  }

  static int? _parseMinor(String value) {
    if (value.isEmpty) return 0;
    final match = RegExp(r'^([+-]?)(\d*)(?:\.(\d{0,2}))?$').firstMatch(value);
    if (match == null) return null;
    final sign = match.group(1) == '-' ? -1 : 1;
    final whole = match.group(2) ?? '';
    final fraction = (match.group(3) ?? '').padRight(2, '0');
    if (whole.isEmpty && fraction.isEmpty) return null;
    return sign *
        ((int.tryParse(whole.isEmpty ? '0' : whole) ?? 0) * 100 +
            (int.tryParse(fraction.isEmpty ? '0' : fraction) ?? 0));
  }

  static int? _parseScaled(String value) {
    if (value.isEmpty) return 0;
    final match = RegExp(r'^([+-]?)(\d*)(?:\.(\d{0,3}))?$').firstMatch(value);
    if (match == null) return null;
    final sign = match.group(1) == '-' ? -1 : 1;
    final whole = match.group(2) ?? '';
    final fraction = (match.group(3) ?? '').padRight(3, '0');
    if (whole.isEmpty && fraction.isEmpty) return null;
    return sign *
        ((int.tryParse(whole.isEmpty ? '0' : whole) ?? 0) * 1000 +
            (int.tryParse(fraction.isEmpty ? '0' : fraction) ?? 0));
  }
}

/// A CSV row accepted for import, held until the transaction runs.
class _PendingImport {
  const _PendingImport({
    required this.lineNumber,
    required this.name,
    required this.purchaseCostMinor,
    required this.sellingPriceMinor,
    required this.minimumStockScaled,
    required this.barcodes,
    required this.isActive,
    this.sku,
    this.categoryId,
    this.unitId,
    this.description,
  });

  final int lineNumber;
  final String name;
  final String? sku;
  final int? categoryId;
  final int? unitId;
  final int purchaseCostMinor;
  final int sellingPriceMinor;
  final int minimumStockScaled;
  final List<String> barcodes;
  final String? description;
  final bool isActive;
}

/// The outcome of a CSV import, row by row.
///
/// Reports what happened to every row rather than a single success or failure, so
/// a partially bad file is actionable: the user sees exactly which lines to fix.
class ImportReport {
  ImportReport();

  final List<ImportRowResult> _results = <ImportRowResult>[];

  int createdCount = 0;
  int updatedCount = 0;

  List<ImportRowResult> get results => List.unmodifiable(_results);

  /// Rows that were skipped, with the reason.
  List<ImportRowResult> get rejectedRows => _results
      .where((result) => result.outcome == ImportOutcome.rejected)
      .toList(growable: false);

  bool get hasRejections => rejectedRows.isNotEmpty;

  int get rejectedCount => rejectedRows.length;

  int get totalRows => _results.length;

  void created(int line, String name) {
    createdCount++;
    _results.add(ImportRowResult(line, name, ImportOutcome.created));
  }

  void updated(int line, String name) {
    updatedCount++;
    _results.add(ImportRowResult(line, name, ImportOutcome.updated));
  }

  void rejected(int line, String reason) {
    _results.add(ImportRowResult(line, reason, ImportOutcome.rejected));
  }
}

/// What happened to one row of an import.
class ImportRowResult {
  const ImportRowResult(this.lineNumber, this.message, this.outcome);

  final int lineNumber;
  final String message;
  final ImportOutcome outcome;
}

/// The disposition of an imported row.
enum ImportOutcome { created, updated, rejected }

import 'package:drift/drift.dart';

import '../../../core/constants/enums.dart';
import '../../../core/errors/failures.dart';
import '../../../core/utils/pagination.dart';
import '../../../core/utils/timestamps.dart';
import '../../../infrastructure/database/app_database.dart';
import '../domain/entities/stock_movement.dart';
import '../domain/services/inventory_policy.dart';

/// The single write path for stock.
///
/// Every quantity change in the application goes through [apply]. It appends an
/// [InventoryMovements] row and updates the [ProductStock] cache in the same
/// call, so the ledger and the cached balance can never diverge through normal
/// operation. Nothing else in the codebase is permitted to write either table.
///
/// ## Why the ledger and the cache are written together
///
/// The ledger is the source of truth and is append-only. The cache exists because
/// summing a product's whole history on every POS keystroke would not scale. If
/// they were written in separate steps, a crash between them would leave a
/// permanent discrepancy. Writing both inside the caller's transaction makes that
/// impossible: either both land or neither does.
class InventoryService {
  InventoryService(this._db);

  final AppDatabase _db;

  /// Applies a signed stock movement and returns the resulting position.
  ///
  /// [signedQuantityScaled] is positive to increase stock and negative to
  /// decrease it, and its sign must agree with [movementType]'s declared
  /// direction; a mismatch throws rather than silently inverting the ledger.
  ///
  /// [unitCost] is the per-unit cost in base-currency minor units. It is required
  /// for inbound movements and ignored for outbound ones. For a
  /// [MovementType.supplierReturn] it is the cost of the units going back, which
  /// is what lets the weighted average be unwound correctly.
  ///
  /// Must be called inside a transaction when it is part of a larger document
  /// (a sale, a purchase, an adjustment). The caller owns the transaction so that
  /// a failure later in the document rolls the stock change back with it.
  Future<StockPosition> apply({
    required int productId,
    required MovementType movementType,
    required int signedQuantityScaled,
    required ReferenceType referenceType,
    required bool allowNegativeStock,
    int? referenceId,
    int unitCost = 0,
    String? notes,
    DateTime? occurredAt,
  }) async {
    if (referenceType == ReferenceType.manual && referenceId != null) {
      throw const ValidationFailure(
        'A manual movement cannot reference another document',
        field: 'referenceId',
      );
    }

    final product = await (_db.select(_db.products)
          ..where((t) => t.id.equals(productId)))
        .getSingleOrNull();
    if (product == null) {
      throw NotFoundFailure(
        'Product not found',
        details: <String, Object?>{'productId': productId},
      );
    }

    final current = await positionOf(productId);

    // Guard the direction *before* the stock check so a sign error reports as a
    // sign error rather than as a misleading "insufficient stock".
    final newBalance = InventoryPolicy.balanceAfter(
      movementType: movementType,
      signedQuantityScaled: signedQuantityScaled,
      currentScaled: current.quantityScaled,
    );

    if (signedQuantityScaled < 0) {
      InventoryPolicy.assertCanIssue(
        productId: productId,
        productName: product.name,
        availableScaled: current.quantityScaled,
        requestedScaled: signedQuantityScaled.abs(),
        allowNegativeStock: allowNegativeStock,
      );
    }

    final newAverageCost = InventoryPolicy.averageCostAfter(
      movementType: movementType,
      currentQuantityScaled: current.quantityScaled,
      currentAverageCost: current.averageCostMinor,
      signedQuantityScaled: signedQuantityScaled,
      unitCost: unitCost,
    );

    final timestamp = toStorageTimestamp(occurredAt ?? DateTime.now());

    await _db.into(_db.inventoryMovements).insert(
          InventoryMovementsCompanion.insert(
            productId: productId,
            movementType: movementType.wireValue,
            quantityScaled: signedQuantityScaled,
            balanceAfterScaled: newBalance,
            referenceType: referenceType.wireValue,
            referenceId: Value(referenceId),
            notes: Value(notes),
            createdAt: timestamp,
          ),
        );

    await _upsertStockCache(
      productId: productId,
      quantityScaled: newBalance,
      averageCost: newAverageCost,
      timestamp: timestamp,
    );

    return StockPosition(
      productId: productId,
      quantityScaled: newBalance,
      averageCostMinor: newAverageCost,
    );
  }

  /// Writes the cached balance, inserting the row on first movement.
  Future<void> _upsertStockCache({
    required int productId,
    required int quantityScaled,
    required int averageCost,
    required String timestamp,
  }) async {
    final existing = await (_db.select(_db.productStock)
          ..where((t) => t.productId.equals(productId)))
        .getSingleOrNull();

    if (existing == null) {
      await _db.into(_db.productStock).insert(
            ProductStockCompanion.insert(
              productId: Value(productId),
              quantityScaled: Value(quantityScaled),
              averageCost: Value(averageCost),
              updatedAt: timestamp,
            ),
          );
    } else {
      await (_db.update(_db.productStock)
            ..where((t) => t.productId.equals(productId)))
          .write(
        ProductStockCompanion(
          quantityScaled: Value(quantityScaled),
          averageCost: Value(averageCost),
          updatedAt: Value(timestamp),
        ),
      );
    }
  }

  /// The current position of a product.
  ///
  /// Returns [StockPosition.absent] when the product has never moved stock,
  /// which is arithmetic-equivalent to a zero balance but distinguishable.
  Future<StockPosition> positionOf(int productId) async {
    final row = await (_db.select(_db.productStock)
          ..where((t) => t.productId.equals(productId)))
        .getSingleOrNull();
    if (row == null) return StockPosition.absent(productId);
    return StockPosition(
      productId: productId,
      quantityScaled: row.quantityScaled,
      averageCostMinor: row.averageCost,
    );
  }

  /// Positions for several products in one query, for a cart or a listing.
  ///
  /// Products with no stock row are omitted from the map; callers treat a missing
  /// entry as [StockPosition.absent].
  Future<Map<int, StockPosition>> positionsOf(Iterable<int> productIds) async {
    final ids = productIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const <int, StockPosition>{};
    final rows = await (_db.select(_db.productStock)
          ..where((t) => t.productId.isIn(ids)))
        .get();
    return <int, StockPosition>{
      for (final row in rows)
        row.productId: StockPosition(
          productId: row.productId,
          quantityScaled: row.quantityScaled,
          averageCostMinor: row.averageCost,
        ),
    };
  }

  /// One page of a product's movement history, newest first.
  Future<Page<StockMovement>> history(
    int productId, {
    PageRequest request = const PageRequest(),
  }) async {
    final query = _db.select(_db.inventoryMovements)
      ..where((t) => t.productId.equals(productId))
      ..orderBy(<OrderClauseGenerator<$InventoryMovementsTable>>[
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(request.effectiveLimit, offset: request.offset);

    final rows = await query.get();

    final countQuery = _db.selectOnly(_db.inventoryMovements)
      ..addColumns(<Expression<Object>>[countAll()])
      ..where(_db.inventoryMovements.productId.equals(productId));
    final total = await countQuery
        .map((row) => row.read(countAll()) ?? 0)
        .getSingle();

    final product = await (_db.select(_db.products)
          ..where((t) => t.id.equals(productId)))
        .getSingleOrNull();

    return Page<StockMovement>(
      items: rows
          .map((row) => _toMovement(row, productName: product?.name))
          .toList(growable: false),
      totalCount: total,
      request: request,
    );
  }

  /// Reconciles the cached balances against the ledger.
  ///
  /// Returns one entry per product whose cache disagrees with the signed sum of
  /// its movements, plus any product that has movements but no cache row. An
  /// empty list means the two agree, which is the invariant the whole inventory
  /// design depends on. Exposed so the condition can be checked in a test and
  /// surfaced in a maintenance screen rather than assumed.
  Future<List<StockReconciliation>> reconcile() async {
    final rows = await _db.customSelect(
      '''
      SELECT p.id AS product_id,
             p.name AS product_name,
             COALESCE(s.quantity_scaled, 0) AS cached_scaled,
             COALESCE(m.ledger_scaled, 0) AS ledger_scaled
      FROM products p
      LEFT JOIN product_stock s ON s.product_id = p.id
      LEFT JOIN (
        SELECT product_id, SUM(quantity_scaled) AS ledger_scaled
        FROM inventory_movements
        GROUP BY product_id
      ) m ON m.product_id = p.id
      WHERE COALESCE(s.quantity_scaled, 0) <> COALESCE(m.ledger_scaled, 0)
      ORDER BY p.id
      ''',
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.products,
        _db.productStock,
        _db.inventoryMovements,
      },
    ).get();

    return rows
        .map(
          (row) => StockReconciliation(
            productId: row.read<int>('product_id'),
            productName: row.read<String>('product_name'),
            cachedScaled: row.read<int>('cached_scaled'),
            ledgerScaled: row.read<int>('ledger_scaled'),
          ),
        )
        .toList(growable: false);
  }

  /// Total value of all stock on hand, in base-currency minor units.
  ///
  /// A single query rather than a loop, because the dashboard and the inventory
  /// valuation report both need it and neither should load the catalog.
  Future<int> totalStockValueMinor() async {
    final row = await _db.customSelect(
      '''
      SELECT COALESCE(SUM(
        CASE WHEN s.quantity_scaled > 0
             THEN (s.quantity_scaled * s.average_cost) / 1000
             ELSE 0 END
      ), 0) AS total
      FROM product_stock s
      JOIN products p ON p.id = s.product_id
      WHERE p.is_active = 1
      ''',
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.productStock,
        _db.products,
      },
    ).getSingle();
    return row.read<int>('total');
  }

  /// Posts a stock adjustment document atomically.
  ///
  /// Each line is applied through [apply], so the adjustment obeys exactly the
  /// same rules as a sale or a purchase and produces the same kind of ledger
  /// entry. The whole document is one transaction: a failure on any line leaves
  /// no adjustment, no movements and no cache changes.
  Future<String> postAdjustment({
    required StockAdjustmentReason reason,
    required List<StockAdjustmentLine> lines,
    required bool allowNegativeStock,
    required String adjustmentNo,
    int? userId,
    String? notes,
    DateTime? occurredAt,
  }) async {
    if (lines.isEmpty) {
      throw const ValidationFailure(
        'A stock adjustment needs at least one line',
        field: 'lines',
      );
    }
    for (final line in lines) {
      if (line.quantityScaled == 0) {
        throw ValidationFailure(
          'Adjustment quantity cannot be zero',
          field: 'quantity',
          details: <String, Object?>{'productId': line.productId},
        );
      }
    }

    return _db.transaction(() async {
      final timestamp = toStorageTimestamp(occurredAt ?? DateTime.now());
      final adjustmentId = await _db.into(_db.stockAdjustments).insert(
            StockAdjustmentsCompanion.insert(
              adjustmentNo: adjustmentNo,
              reason: reason.wireValue,
              status: DocumentStatus.posted.wireValue,
              createdAt: timestamp,
              notes: Value(notes),
              userId: Value(userId),
            ),
          );

      for (final line in lines) {
        final movementType = line.quantityScaled > 0
            ? MovementType.adjustmentIn
            : MovementType.adjustmentOut;

        await _db.into(_db.stockAdjustmentItems).insert(
              StockAdjustmentItemsCompanion.insert(
                stockAdjustmentId: adjustmentId,
                productId: line.productId,
                quantityScaled: line.quantityScaled,
                unitCost: Value(line.unitCost),
                notes: Value(line.notes),
              ),
            );

        await apply(
          productId: line.productId,
          movementType: movementType,
          signedQuantityScaled: line.quantityScaled,
          referenceType: ReferenceType.stockAdjustment,
          referenceId: adjustmentId,
          allowNegativeStock: allowNegativeStock,
          unitCost: line.unitCost,
          notes: notes,
          occurredAt: occurredAt,
        );
      }

      return adjustmentNo;
    });
  }

  StockMovement _toMovement(
    InventoryMovementRow row, {
    String? productName,
  }) {
    return StockMovement(
      id: row.id,
      productId: row.productId,
      movementType: MovementType.fromWire(row.movementType),
      quantityScaled: row.quantityScaled,
      balanceAfterScaled: row.balanceAfterScaled,
      referenceType: ReferenceType.fromWire(row.referenceType),
      referenceId: row.referenceId,
      notes: row.notes,
      createdAtStorage: row.createdAt,
      productName: productName,
    );
  }
}

/// One line of a stock adjustment document.
class StockAdjustmentLine {
  const StockAdjustmentLine({
    required this.productId,
    required this.quantityScaled,
    this.unitCost = 0,
    this.notes,
  });

  final int productId;

  /// Signed: positive is a count-in, negative is a count-out or a write-off.
  final int quantityScaled;

  /// Cost to use for an inbound line, in base-currency minor units.
  final int unitCost;

  final String? notes;
}

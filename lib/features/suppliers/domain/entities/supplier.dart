/// A supplier record.
class Supplier {
  const Supplier({
    required this.id,
    required this.name,
    required this.isActive,
    this.phone,
    this.email,
    this.address,
    this.notes,
  });

  final int id;
  final String name;
  final String? phone;
  final String? email;
  final String? address;
  final String? notes;
  final bool isActive;
}

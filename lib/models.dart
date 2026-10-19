import 'package:intl/intl.dart';

final _money = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
String formatMoney(num value) => _money.format(value);

const defaultCategories = ['Tea', 'Coffee', 'Juices', 'Burgers', 'Snacks'];

class MenuItem {
  final String id;
  final String name;
  final String category;
  final double price;
  final bool available;

  const MenuItem({
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    this.available = true,
  });

  MenuItem copyWith({String? name, String? category, double? price, bool? available}) => MenuItem(
    id: id,
    name: name ?? this.name,
    category: category ?? this.category,
    price: price ?? this.price,
    available: available ?? this.available,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'price': price,
    'available': available,
  };

  factory MenuItem.fromJson(Map<String, dynamic> j) => MenuItem(
    id: j['id'] as String,
    name: j['name'] as String,
    category: j['category'] as String,
    price: (j['price'] as num).toDouble(),
    available: j['available'] as bool? ?? true,
  );
}

class OrderItem {
  final String menuId;
  final String name;
  final double price;
  final int qty;
  final String note;
  final bool done; // ticked off by the kitchen

  const OrderItem({
    required this.menuId,
    required this.name,
    required this.price,
    required this.qty,
    this.note = '',
    this.done = false,
  });

  double get total => price * qty;

  OrderItem copyWith({int? qty, String? note, bool? done}) => OrderItem(
    menuId: menuId,
    name: name,
    price: price,
    qty: qty ?? this.qty,
    note: note ?? this.note,
    done: done ?? this.done,
  );

  Map<String, dynamic> toJson() => {
    'menuId': menuId,
    'name': name,
    'price': price,
    'qty': qty,
    'note': note,
    'done': done,
  };

  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
    menuId: j['menuId'] as String,
    name: j['name'] as String,
    price: (j['price'] as num).toDouble(),
    qty: j['qty'] as int,
    note: j['note'] as String? ?? '',
    done: j['done'] as bool? ?? false,
  );
}

enum OrderStatus {
  newOrder('New'),
  preparing('Preparing'),
  ready('Ready'),
  served('Served'),
  cancelled('Cancelled');

  final String label;
  const OrderStatus(this.label);

  OrderStatus? get next => switch (this) {
    OrderStatus.newOrder => OrderStatus.preparing,
    OrderStatus.preparing => OrderStatus.ready,
    OrderStatus.ready => OrderStatus.served,
    _ => null,
  };

  bool get isActive => this == newOrder || this == preparing || this == ready;
}

/// One kitchen ticket (KOT). A table can have several tickets; the bill adds
/// together every unpaid ticket for that table.
class Order {
  final String id;
  final int number;
  final String table;
  final List<OrderItem> items;
  final String note;
  final String placedBy;
  final OrderStatus status;
  final DateTime createdAt;
  final DateTime? readyAt;
  final DateTime? editedAt; // set when a waiter changes the order
  final DateTime? paidAt;
  final String? paymentMethod;

  const Order({
    required this.id,
    required this.number,
    required this.table,
    required this.items,
    required this.status,
    required this.createdAt,
    this.note = '',
    this.placedBy = '',
    this.readyAt,
    this.editedAt,
    this.paidAt,
    this.paymentMethod,
  });

  double get total => items.fold(0, (sum, i) => sum + i.total);
  bool get isPaid => paidAt != null;
  bool get isBillable => !isPaid && status != OrderStatus.cancelled;

  /// The waiter can still change or add items: the food isn't ready yet.
  bool get isEditable => !isPaid && (status == OrderStatus.newOrder || status == OrderStatus.preparing);

  /// Can be cancelled until it's paid.
  bool get isCancellable => isBillable;

  Order copyWith({
    List<OrderItem>? items,
    String? note,
    OrderStatus? status,
    DateTime? readyAt,
    DateTime? editedAt,
    DateTime? paidAt,
    String? paymentMethod,
  }) => Order(
    id: id,
    number: number,
    table: table,
    items: items ?? this.items,
    note: note ?? this.note,
    placedBy: placedBy,
    status: status ?? this.status,
    createdAt: createdAt,
    readyAt: readyAt ?? this.readyAt,
    editedAt: editedAt ?? this.editedAt,
    paidAt: paidAt ?? this.paidAt,
    paymentMethod: paymentMethod ?? this.paymentMethod,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'number': number,
    'table': table,
    'items': items.map((i) => i.toJson()).toList(),
    'note': note,
    'placedBy': placedBy,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'readyAt': readyAt?.toIso8601String(),
    'editedAt': editedAt?.toIso8601String(),
    'paidAt': paidAt?.toIso8601String(),
    'paymentMethod': paymentMethod,
  };

  factory Order.fromJson(Map<String, dynamic> j) => Order(
    id: j['id'] as String,
    number: j['number'] as int,
    table: j['table'] as String,
    items: (j['items'] as List).map((e) => OrderItem.fromJson(e as Map<String, dynamic>)).toList(),
    note: j['note'] as String? ?? '',
    placedBy: j['placedBy'] as String? ?? '',
    status: OrderStatus.values.byName(j['status'] as String),
    createdAt: DateTime.parse(j['createdAt'] as String),
    readyAt: j['readyAt'] == null ? null : DateTime.parse(j['readyAt'] as String),
    editedAt: j['editedAt'] == null ? null : DateTime.parse(j['editedAt'] as String),
    paidAt: j['paidAt'] == null ? null : DateTime.parse(j['paidAt'] as String),
    paymentMethod: j['paymentMethod'] as String?,
  );
}

class ShopSettings {
  final String shopName;
  final int tableCount;
  final bool parcelEnabled;
  final String adminPin;
  final List<String> categories;

  const ShopSettings({
    this.shopName = 'Ordova Café',
    this.tableCount = 8,
    this.parcelEnabled = true,
    this.adminPin = '1234',
    this.categories = defaultCategories,
  });

  /// Table labels shown to the waiter. "Parcel" is for take-away orders.
  List<String> get tables => [for (var i = 1; i <= tableCount; i++) 'T$i', if (parcelEnabled) 'Parcel'];

  ShopSettings copyWith({
    String? shopName,
    int? tableCount,
    bool? parcelEnabled,
    String? adminPin,
    List<String>? categories,
  }) => ShopSettings(
    shopName: shopName ?? this.shopName,
    tableCount: tableCount ?? this.tableCount,
    parcelEnabled: parcelEnabled ?? this.parcelEnabled,
    adminPin: adminPin ?? this.adminPin,
    categories: categories ?? this.categories,
  );

  Map<String, dynamic> toJson() => {
    'shopName': shopName,
    'tableCount': tableCount,
    'parcelEnabled': parcelEnabled,
    'adminPin': adminPin,
    'categories': categories,
  };

  factory ShopSettings.fromJson(Map<String, dynamic> j) => ShopSettings(
    shopName: j['shopName'] as String? ?? 'Ordova Café',
    tableCount: j['tableCount'] as int? ?? 8,
    parcelEnabled: j['parcelEnabled'] as bool? ?? true,
    adminPin: j['adminPin'] as String? ?? '1234',
    categories: (j['categories'] as List?)?.cast<String>() ?? defaultCategories,
  );
}

/// Everything the kitchen server knows. Sent to every device on each change.
class ShopState {
  final ShopSettings settings;
  final List<MenuItem> menu;
  final List<Order> orders;
  final int nextOrderNumber;

  const ShopState({required this.settings, required this.menu, required this.orders, required this.nextOrderNumber});

  static const empty = ShopState(settings: ShopSettings(), menu: [], orders: [], nextOrderNumber: 1);

  List<Order> ordersForTable(String table) => orders.where((o) => o.table == table).toList();
  List<Order> billFor(String table) => orders.where((o) => o.table == table && o.isBillable).toList();

  Map<String, dynamic> toJson() => {
    'settings': settings.toJson(),
    'menu': menu.map((m) => m.toJson()).toList(),
    'orders': orders.map((o) => o.toJson()).toList(),
    'nextOrderNumber': nextOrderNumber,
  };

  factory ShopState.fromJson(Map<String, dynamic> j) => ShopState(
    settings: ShopSettings.fromJson(j['settings'] as Map<String, dynamic>),
    menu: (j['menu'] as List).map((e) => MenuItem.fromJson(e as Map<String, dynamic>)).toList(),
    orders: (j['orders'] as List).map((e) => Order.fromJson(e as Map<String, dynamic>)).toList(),
    nextOrderNumber: j['nextOrderNumber'] as int? ?? 1,
  );
}

List<MenuItem> seedMenu() {
  var n = 0;
  MenuItem m(String name, String cat, double price) =>
      MenuItem(id: 'seed${n++}', name: name, category: cat, price: price);
  return [
    m('Tea', 'Tea', 15),
    m('Ginger Tea', 'Tea', 20),
    m('Masala Tea', 'Tea', 25),
    m('Lemon Tea', 'Tea', 20),
    m('Black Tea', 'Tea', 12),
    m('Coffee', 'Coffee', 20),
    m('Black Coffee', 'Coffee', 15),
    m('Cappuccino', 'Coffee', 60),
    m('Cold Coffee', 'Coffee', 70),
    m('Lime Juice', 'Juices', 30),
    m('Orange Juice', 'Juices', 60),
    m('Mango Shake', 'Juices', 80),
    m('Watermelon Juice', 'Juices', 50),
    m('Veg Burger', 'Burgers', 80),
    m('Chicken Burger', 'Burgers', 110),
    m('Cheese Burger', 'Burgers', 120),
    m('French Fries', 'Snacks', 70),
    m('Samosa', 'Snacks', 15),
    m('Puffs', 'Snacks', 20),
    m('Sandwich', 'Snacks', 50),
  ];
}

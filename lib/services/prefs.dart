import 'package:shared_preferences/shared_preferences.dart';

enum DeviceRole { kitchen, waiter }

/// Per-device settings (not shared with other devices).
class Prefs {
  Prefs._(this._p);
  static late Prefs instance;
  final SharedPreferences _p;

  static Future<void> init() async => instance = Prefs._(await SharedPreferences.getInstance());

  DeviceRole? get role {
    final r = _p.getString('role');
    return r == null ? null : DeviceRole.values.byName(r);
  }

  Future<void> setRole(DeviceRole? role) => role == null ? _p.remove('role') : _p.setString('role', role.name);

  String? get serverHost => _p.getString('serverHost');
  Future<void> setServerHost(String host) => _p.setString('serverHost', host);

  String get staffName => _p.getString('staffName') ?? '';
  Future<void> setStaffName(String name) => _p.setString('staffName', name);
}

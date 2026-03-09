import 'package:mesh_utility/transport/ble_transport.dart';
import 'package:mesh_utility/transport/transport_core.dart';

export 'package:mesh_utility/transport/transport_core.dart';

Transport createDefaultTransport() {
  return BleTransport();
}

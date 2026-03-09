class MeshNode {
  MeshNode({
    required this.id,
    required this.nodeId,
    required this.name,
    required this.hardwareType,
    required this.lastSeen,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String nodeId;
  final String? name;
  final String? hardwareType;
  final DateTime lastSeen;
  final double? latitude;
  final double? longitude;
}

class Household {
  final String id;
  final String? serverId;
  final String headName;
  final int memberCount;
  final String settlement;
  final int lastSeq;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Household({
    required this.id,
    this.serverId,
    required this.headName,
    required this.memberCount,
    required this.settlement,
    this.lastSeq = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'server_id': serverId,
      'head_name': headName,
      'member_count': memberCount,
      'settlement': settlement,
      'last_seq': lastSeq,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Household.fromMap(Map<String, dynamic> map) {
    return Household(
      id: map['id'] as String,
      serverId: map['server_id'] as String?,
      headName: map['head_name'] as String,
      memberCount: map['member_count'] as int,
      settlement: map['settlement'] as String,
      lastSeq: map['last_seq'] as int,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}

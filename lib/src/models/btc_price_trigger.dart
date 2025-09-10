class BtcPriceTrigger {
  BtcPriceTrigger({
    required this.id,
    required this.userId,
    required this.symbol,
    required this.triggerType, // 'ABOVE' or 'BELOW'
    required this.triggerPrice,
    required this.triggerNode,
    this.executionId,          // new optional field
    DateTime? createdAt,        // optional, default to now if null
  }) : createdAt = createdAt ?? DateTime.now();

  final int id;
  final String userId;
  final String symbol;
  final String triggerType;
  final double triggerPrice;
  final String triggerNode;
  final int? executionId;      // optional
  final DateTime createdAt;

  factory BtcPriceTrigger.fromJson(Map<String, dynamic> json) {
    return BtcPriceTrigger(
      id: (json['id'] as num).toInt(),
      userId: json['user_id'] as String,
      symbol: json['symbol'] as String,
      triggerType: json['trigger_type'] as String,
      triggerPrice: (json['trigger_price'] as num).toDouble(),
      triggerNode: json['trigger_node'] as String,
      executionId: json['execution_id'] != null
          ? (json['execution_id'] as num).toInt()
          : null,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'symbol': symbol,
    'trigger_type': triggerType,
    'trigger_price': triggerPrice,
    'trigger_node': triggerNode,
    'execution_id': executionId,
    'created_at': createdAt.toIso8601String(),
  };
}

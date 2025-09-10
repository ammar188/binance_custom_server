class GridExecution {
  GridExecution({
    required this.id,
    required this.upperLimit,
    required this.lowerLimit,
    required this.tradeAmount,
    required this.intervalSize,
    required this.sampleTradePrice,
    required this.symbol,
    required this.userId,
    this.status = 'stopped',
    this.market = 'spot',
    this.marginMode = 'isolated',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final int id;
  final double upperLimit;
  final double lowerLimit;
  final double tradeAmount;
  final double intervalSize;
  final double sampleTradePrice;
  final String symbol;
  final String userId;
  final String status;      // execution_status
  final String market;      // execution_market
  final String marginMode;  // execution_margin_mode
  final DateTime createdAt;

  /// Create instance from JSON
  factory GridExecution.fromJson(Map<String, dynamic> json) {
    return GridExecution(
      id: (json['id'] as num).toInt(),
      upperLimit: (json['upper_limit'] as num).toDouble(),
      lowerLimit: (json['lower_limit'] as num).toDouble(),
      tradeAmount: (json['trade_amount'] as num).toDouble(),
      intervalSize: (json['interval_size'] as num).toDouble(),
      sampleTradePrice: (json['sample_trade_price'] as num).toDouble(),
      symbol: json['symbol'] as String,
      userId: json['user_id'] as String,
      status: json['status'] as String? ?? 'stopped',
      market: json['market'] as String? ?? 'spot',
      marginMode: json['margin_mode'] as String? ?? 'isolated',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
    );
  }

  /// Convert instance to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'upper_limit': upperLimit,
      'lower_limit': lowerLimit,
      'trade_amount': tradeAmount,
      'interval_size': intervalSize,
      'sample_trade_price': sampleTradePrice,
      'symbol': symbol,
      'user_id': userId,
      'status': status,
      'market': market,
      'margin_mode': marginMode,
      'created_at': createdAt.toIso8601String(),
    };
  }
}

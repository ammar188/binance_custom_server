import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:binance_custom_server/src/models/execution.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:supabase/supabase.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum ExecutionMarket {
  margin,
  future,
}

class StartCommand extends Command<int> {
  StartCommand({required Logger logger}) : _logger = logger {
    argParser.addOption(
      'config',
      abbr: 'f',
      help: 'Path to the JSON config file with Supabase credentials',
      defaultsTo: 'config.json',
    );
  }

  @override
  String get description =>
      'Start BTC listener and update triggers in Supabase';

  @override
  String get name => 'start';

  final Logger _logger;
  late SupabaseClient _supabase;
  late String _configFile;
  late final ExecutionMarket _marketType;

  /// All active executions (id -> execution)
  final activeExecutions = <int, GridExecution>{};

  /// Cache grid nodes per execution (execId -> sorted node list)
  final _nodesByExec = <int, List<double>>{};

  /// Remember last seen ticker price to detect crossings
  double? _lastPrice;

  /// Dedup: remember last side we triggered per (execId|node)
  /// value is 'ABOVE' or 'BELOW'. We only insert again once it crosses back.
  final _lastSideByNodeKey = <String, String>{};

  @override
  Future<int> run() async {
    if (!await _loadConfig()) return ExitCode.noInput.code;
    await loadActiveExecutions(_supabase);
    _primeNodesCache();
    _subscribeToExecutionChanges();
    _connectBinanceWebSocket();
    return _keepRunning();
  }

  /// ----------------- Private Methods -----------------
  Future<bool> _loadConfig() async {
    final configPath = argResults?['config'] as String;
    final file = File(configPath);
    _configFile = configPath;

    if (!file.existsSync()) {
      _logger.err('Config file not found at $configPath');
      return false;
    }

    final config = jsonDecode(file.readAsStringSync());
    _supabase = SupabaseClient(
      config['supabase_url'] as String,
      config['supabase_service_role_key'] as String, // use service role key
    );
    // --- Read market_type from config ---
    if (config['market_type'] != null) {
      final marketStr = (config['market_type'] as String).toLowerCase();
      switch (marketStr) {
        case 'margin':
          _marketType = ExecutionMarket.margin;
          break;
        case 'future':
          _marketType = ExecutionMarket.future;
          break;
        default:
          _logger.err('Unknown market_type "$marketStr", defaulting to future');
          _marketType = ExecutionMarket.future;
      }
    } else {
      _logger.err('market_type not found in config, defaulting to margin');
      _marketType = ExecutionMarket.margin; // default
    }

    return true;
  }

  Future<void> loadActiveExecutions(SupabaseClient supabase) async {
    // Convert enum to string matching the database enum
    final marketStr = _marketType
        .name; // ExecutionMarket.margin -> "margin", ExecutionMarket.future -> "future"

    final response = await supabase
        .from('grid_executions')
        .select()
        .neq('status', 'stopped')
        .neq('status', 'paused')
        .eq('market', marketStr); // filter by market type

    if (response.isEmpty) {
      _logger.info('No active executions found for market type $marketStr.');
      return;
    }

    for (final row in response as List<dynamic>) {
      final exec = GridExecution.fromJson(row as Map<String, dynamic>);
      activeExecutions[exec.id] = exec;
    }

    _logger.info(
      'Loaded ${activeExecutions.length} active executions for market type $marketStr.',
    );
  }

  /// Build nodes cache for all current executions
  void _primeNodesCache() {
    _nodesByExec
      ..clear()
      ..addEntries(
        activeExecutions.values.map(
          (e) => MapEntry(e.id, _calculateGridNodes(e)),
        ),
      );
  }

  void _subscribeToExecutionChanges() {
    _supabase
        .channel('grid_executions_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'grid_executions',
          callback: (payload) {
            switch (payload.eventType) {
              case PostgresChangeEvent.insert:
              case PostgresChangeEvent.update:
                _handleExecutionUpsert(payload.newRecord);
              case PostgresChangeEvent.delete:
                _handleExecutionDelete(payload.oldRecord);
              case PostgresChangeEvent.all:
                // No-op (exhaustive switch for linter)
                break;
            }
          },
        )
        .subscribe();
  }

  void _handleExecutionUpsert(Map<String, dynamic>? data) {
    if (data == null) return;
    final exec = GridExecution.fromJson(data);
    final marketStr = _marketType.name;
    final wasActive = activeExecutions.containsKey(exec.id);

    if (exec.status == 'stopped' ||
        exec.status == 'paused' ||
        exec.market != marketStr) {
      // Remove from active if it was previously tracked
      if (wasActive) {
        activeExecutions.remove(exec.id);
        _nodesByExec.remove(exec.id);
        _clearDedupForExec(exec.id);
        _logger.info(
          'Execution removed due to market/status change: ${exec.id}',
        );
      } else {
        _logger.info(
          'Execution skipped (wrong market or stopped/paused): ${exec.id}',
        );
      }
      return;
    }

    // Add or update execution if it now matches our market type
    activeExecutions[exec.id] = exec;
    _nodesByExec[exec.id] = _calculateGridNodes(exec);
    _clearDedupForExec(exec.id); // reset dedup on new config
    _logger.info('Execution upserted/added: ${exec.id}');
  }

  void _handleExecutionDelete(Map<String, dynamic>? old) {
    if (old == null) return;
    final id = old['id'] as int;
    final execMarket = old['market'] as String? ?? '';
    final marketStr = _marketType.name;

    // Only remove if it belongs to our market type
    if (execMarket == marketStr && activeExecutions.containsKey(id)) {
      activeExecutions.remove(id);
      _nodesByExec.remove(id);
      _clearDedupForExec(id);
      _logger.info('Execution removed: $id');
    }
  }

  void _connectBinanceWebSocket() {
    const symbol = 'BTCUSDT';
    String wsUrl;

    switch (_marketType) {
      case ExecutionMarket.margin:
        wsUrl =
            'wss://stream.binance.com:9443/ws/${symbol.toLowerCase()}@ticker';
      case ExecutionMarket.future:
        // Use the USD-M future ticker stream
        wsUrl = 'wss://fstream.binance.com/ws/${symbol.toLowerCase()}@ticker';
    }

    _logger.info(
      'Connecting to Binance WebSocket for $symbol (market: ${_marketType.name}) at $wsUrl',
    );

    final channel = WebSocketChannel.connect(Uri.parse(wsUrl));

    channel.stream.listen(
      _handlePriceMessage,
      onDone: () {
        _logger.warn('Binance WebSocket closed. Reconnecting in 5s...');
        Future.delayed(const Duration(seconds: 5), _connectBinanceWebSocket);
      },
      onError: (e) {
        _logger.err('Binance WebSocket error: $e. Reconnecting in 5s...');
        Future.delayed(const Duration(seconds: 5), _connectBinanceWebSocket);
      },
      cancelOnError: false,
    );
  }

  void _handlePriceMessage(dynamic message) {
    try {
      final data = json.decode(message as String) as Map<String, dynamic>;
      final price = double.parse(data['c'] as String);

      // First tick: initialize only
      if (_lastPrice == null) {
        _lastPrice = price;
        return;
      }
      _logger.info('nodes are $price');
      _logger.info('$_lastPrice $price');

      // For each active execution, check crossings against its nodes
      activeExecutions.forEach((execId, exec) {
        final nodes = _nodesByExec[execId] ?? const <double>[];
        for (final node in nodes) {
          final crossedUp = _lastPrice! < node && price >= node;
          final crossedDown = _lastPrice! > node && price <= node;

          if (!crossedUp && !crossedDown) continue;

          final nodeKey = _nodeKey(execId, node);
          if (crossedUp) {
            _logger.info('crossedUp');
            // Only insert if last side wasn't already ABOVE (i.e. avoid duplicates until recross)
            _lastSideByNodeKey[nodeKey] = 'ABOVE';
            _insertTrigger(
              userId: exec.userId,
              symbol: exec.symbol,
              node: node,
              type: 'ABOVE',
              priceAtCross: price,
              executionId: execId,
            );
          } else if (crossedDown) {
            _logger.info('crossedDown');
            _lastSideByNodeKey[nodeKey] = 'BELOW';
            _insertTrigger(
              userId: exec.userId,
              symbol: exec.symbol,
              node: node,
              type: 'BELOW',
              priceAtCross: price,
              executionId: execId,
            );
          }
        }
      });

      _lastPrice = price;
    } catch (_) {
      // ignore parse errors
    }
  }

  /// Insert a trigger row
  /// Insert a trigger row
  Future<void> _insertTrigger({
    required String userId,
    required String symbol,
    required double node,
    required String type, // 'ABOVE' or 'BELOW'
    required double priceAtCross,
    required int executionId,
  }) async {
    try {
      await _supabase.from('btc_price_triggers').insert({
        'user_id': userId,
        'symbol': symbol,
        'trigger_type': type,
        'trigger_price': priceAtCross,
        'execution_id': executionId,
        'trigger_node': node.toString(), // stored as text in your schema
      });

      _logger.info(
        'Inserted trigger: $type @ node $node (price $priceAtCross)',
      );
    } catch (e) {
      if (!(e is PostgrestException && e.code == '23505')) {
        _logger.warn('Insert trigger failed: $e');
      }
    }
  }

  /// Calculate nodes (inclusive of bounds)
  List<double> _calculateGridNodes(GridExecution exec) {
    final nodes = <double>[];
    if (exec.intervalSize <= 0) return nodes;

    // Ensure lower <= upper
    final lower = exec.lowerLimit <= exec.upperLimit
        ? exec.lowerLimit
        : exec.upperLimit;
    final upper = exec.upperLimit >= exec.lowerLimit
        ? exec.upperLimit
        : exec.lowerLimit;

    // numeric stability
    final steps = ((upper - lower) / exec.intervalSize).floor();
    for (var i = 0; i <= steps; i++) {
      final n = lower + exec.intervalSize * i;
      nodes.add(n);
    }

    // If the division isn’t exact, ensure we include the exact upper bound
    if (nodes.isEmpty || nodes.last != upper) {
      nodes.add(upper);
    }

    return nodes;
  }

  void _clearDedupForExec(int execId) {
    // remove dedup entries for this exec
    _lastSideByNodeKey.removeWhere((k, v) => k.startsWith('$execId|'));
  }

  String _nodeKey(int execId, double node) => '$execId|$node';

  Future<int> _keepRunning() async {
    final completer = Completer<void>();
    await completer.future;
    return ExitCode.success.code;
  }
}

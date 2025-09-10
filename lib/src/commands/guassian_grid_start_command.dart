import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:supabase/supabase.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// CLI command to listen to BTC price and handle Gaussian triggers
class GaussianListenerCommand extends Command<int> {
  GaussianListenerCommand({required Logger logger}) : _logger = logger {
    argParser.addOption(
      'config',
      abbr: 'f',
      help: 'Path to JSON config file with Supabase credentials',
      defaultsTo: 'config.json',
    );
  }

  @override
  String get name => 'gaussian-listen';

  @override
  String get description =>
      'Listen to BTC price and insert into gaussian_triggered when nodes are crossed';

  final Logger _logger;
  late SupabaseClient _supabase;
  late String _configFile;

  /// Active executions (executionId -> execution data)
  final _activeExecutions = <int, Map<String, dynamic>>{};

  /// Node prices per execution (sorted)
  final _nodesByExecution = <int, List<double>>{};

  /// Last seen BTC price
  double? _lastPrice;

  @override
  Future<int> run() async {
    _logger.info('Starting GaussianListenerCommand...');
    if (!await _loadConfig()) return ExitCode.noInput.code;

    _logger.info('Fetching active executions and triggers...');
    await _fetchActiveExecutionsAndTriggers();
    _connectToBinanceWebSocket();
    _subscribeToExecutionChanges();
    _subscribeToTriggerChanges();

    return _keepRunning();
  }

  /// Load Supabase URL & Service Role Key from JSON config
  Future<bool> _loadConfig() async {
    final path = argResults?['config'] as String;
    final file = File(path);
    _configFile = path;

    if (!file.existsSync()) {
      _logger.err('Config file not found at $path');
      return false;
    }

    final config = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    _supabase = SupabaseClient(
      config['supabase_url'] as String,
      config['supabase_service_role_key'] as String,
    );

    _logger.info('Loaded Supabase config from $path');
    return true;
  }

  /// Fetch all running Gaussian executions and their active triggers
  Future<void> _fetchActiveExecutionsAndTriggers() async {
    try {
      final newExecutions = <int, Map<String, Object?>>{};
      final newNodesByExecution = <int, List<double>>{};

      final execsResponse = await _supabase
          .from('gaussian_grid_executions')
          .select()
          .eq('current_status', 'running');

      final execs = (execsResponse as List)
          .map((e) => Map<String, Object?>.from(e as Map))
          .toList();

      _logger.info('Fetched ${execs.length} running executions from Supabase');

      for (final exec in execs) {
        final execId = exec['id']! as int;
        newExecutions[execId] = exec;

        // Fetch active triggers for this execution
        final triggersResponse = await _supabase
            .from('gaussian_triggers')
            .select('id, price')
            .eq('grid_execution_id', execId)
            .eq('current_status', 'active');

        final triggers = (triggersResponse as List)
            .map((t) => Map<String, Object?>.from(t as Map))
            .toList();

        final nodes = triggers
            .map((t) => (t['price']! as num).toDouble())
            .toList()
          ..sort();

        newNodesByExecution[execId] = nodes;

        _logger.info('Execution $execId has ${nodes.length} active triggers: $nodes');
      }

      _activeExecutions
        ..clear()
        ..addAll(newExecutions);

      _nodesByExecution
        ..clear()
        ..addAll(newNodesByExecution);

      _logger.info('Loaded ${_activeExecutions.length} active executions with triggers.');
    } catch (e, st) {
      _logger.err('Failed to fetch executions/triggers: $e\n$st');
    }
  }

  /// Connect to Binance BTCUSDT WebSocket
  void _connectToBinanceWebSocket() {
    const symbol = 'BTCUSDT';
    final wsUrl = 'wss://fstream.binance.com/ws/${symbol.toLowerCase()}@ticker';
    _logger.info('Connecting to Binance WebSocket: $wsUrl');

    final channel = WebSocketChannel.connect(Uri.parse(wsUrl));

    channel.stream.listen(
      _handlePriceMessage,
      onDone: () {
        _logger.warn('WebSocket closed. Reconnecting in 5s...');
        Future.delayed(const Duration(seconds: 5), _connectToBinanceWebSocket);
      },
      onError: (e) {
        _logger.err('WebSocket error: $e. Reconnecting in 5s...');
        Future.delayed(const Duration(seconds: 5), _connectToBinanceWebSocket);
      },
      cancelOnError: false,
    );
  }

  /// Handle incoming BTC price message
  void _handlePriceMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      final price = double.parse(data['c'] as String);

      if (_lastPrice == null) {
        _lastPrice = price;
        _logger.info('Initializing lastPrice: $_lastPrice');
        return;
      }

      _activeExecutions.forEach((execId, exec) {
        final nodes = _nodesByExecution[execId] ?? [];
        for (final node in nodes) {
          final crossedUp = _lastPrice! < node && price >= node;
          final crossedDown = _lastPrice! > node && price <= node;

          if (!crossedUp && !crossedDown) continue;

          if (crossedUp) {
            _logger.info('Crossed UP detected for exec=$execId node=$node');
            _insertTriggered(execId, node, price, 'ABOVE');
          } else if (crossedDown) {
            _logger.info('Crossed DOWN detected for exec=$execId node=$node');
            _insertTriggered(execId, node, price, 'BELOW');
          }
        }
      });

      _lastPrice = price;
    } catch (e, st) {
      _logger.err('Error in _handlePriceMessage: $e\n$st');
    }
  }

  /// Insert a row in gaussian_triggered with the correct trigger ID
  Future<void> _insertTriggered(
      int executionId, double nodePrice, double priceAtCross, String type) async {
    try {
      _logger.info('Attempting to insert trigger: exec=$executionId node=$nodePrice type=$type');

      final triggerRow = await _supabase
          .from('gaussian_triggers')
          .select('id')
          .eq('grid_execution_id', executionId)
          .eq('price', nodePrice)
          .eq('current_status', 'active')
          .maybeSingle();

      if (triggerRow == null) {
        _logger.warn('No active trigger found for execution=$executionId price=$nodePrice');
        return;
      }

      final triggerId = triggerRow['id'] as int;

      await _supabase.from('gaussian_triggers_triggered').insert({
        'trigger_id': triggerId,
      });

      _logger.info(
          'Inserted triggered row: execution=$executionId node=$nodePrice type=$type price=$priceAtCross triggerId=$triggerId');
    } catch (e, st) {
      _logger.err('Insert triggered failed: $e\n$st');
    }
  }

  /// Listen for execution updates and refresh nodes if needed
  void _subscribeToExecutionChanges() {
    _supabase
        .channel('gaussian_exec_changes')
        .onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'gaussian_grid_executions',
      callback: (payload) async {
        _logger.info('Execution change detected. Refreshing triggers...');
        await _fetchActiveExecutionsAndTriggers();
      },
    ).subscribe();
  }

  /// Refresh triggers for a single execution
  Future<void> _refreshTriggersForExecution(int execId) async {
    try {
      final triggersResponse = await _supabase
          .from('gaussian_triggers')
          .select('id, price')
          .eq('grid_execution_id', execId)
          .eq('current_status', 'active');

      final triggers = (triggersResponse as List)
          .map((t) => Map<String, Object?>.from(t as Map))
          .toList();

      final nodes = triggers
          .map((t) => (t['price']! as num).toDouble())
          .toList()
        ..sort();

      _nodesByExecution[execId] = nodes;

      _logger.info('Updated ${nodes.length} active triggers for exec=$execId');
    } catch (e, st) {
      _logger.err('Failed to refresh triggers for exec=$execId: $e\n$st');
    }
  }

  /// Listen for trigger updates to refresh only affected execution
  void _subscribeToTriggerChanges() {
    _supabase
        .channel('gaussian_trigger_changes')
        .onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'gaussian_triggers',
      callback: (payload) async {
        final newRow = payload.newRecord;
        final oldRow = payload.oldRecord;
        _logger.info('New payload is $payload');

        final execId =
        (newRow['grid_execution_id'] ?? oldRow['grid_execution_id']) as int?;

        if (execId == null) {
          _logger.warn('Trigger change without execution_id, skipping');
          return;
        }

        _logger.info('Trigger change detected for exec=$execId. Refreshing nodes...');
        await _refreshTriggersForExecution(execId);
      },
    ).subscribe();
  }

  /// Keep the CLI running indefinitely
  Future<int> _keepRunning() async {
    _logger.info('CLI is now running indefinitely...');
    final completer = Completer<void>();
    await completer.future;
    return ExitCode.success.code;
  }
}

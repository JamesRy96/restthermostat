import 'package:dio/dio.dart';

import '../models/devices_response.dart';
import '../models/schedule.dart';
import 'app_logger.dart';
import 'hosted_api.dart';
import 'nle_api_logging_interceptor.dart';
import 'nle_error.dart';

class NleApiClient {
  final Dio dio;
  final AppLogger? _logger;

  /// True when talking to the hosted NoLongerEvil service
  /// (`https://nolongerevil.com`) instead of a self-hosted Control API.
  /// Reads and writes are translated at this boundary; see `hosted_api.dart`.
  final bool hosted;

  /// Hosted mode only: serial → hosted device id, and serial → last-known
  /// mode. Refreshed on every [fetchDevicesJson].
  final Map<String, String> _hostedIds = {};
  final Map<String, String> _hostedModes = {};

  // Initializing-formal would require the constructor param to be named
  // `_logger` (matching the field), which is awkward for a public API. The
  // `:` form keeps the named arg `logger`.
  // ignore: prefer_initializing_formals
  NleApiClient({required this.dio, AppLogger? logger, this.hosted = false})
    : _logger = logger;

  /// Production factory. Installs the diagnostic-logging interceptor so every
  /// HTTP call appears in [AppLogger]; logs the configured auth presence once
  /// at construction time (never the credential value).
  ///
  /// [authHeaders] are merged verbatim into every request — this covers both
  /// `Authorization`-style schemes and custom header pairs (e.g. Cloudflare
  /// Access service tokens). See [AuthConfig.headers].
  ///
  /// The raw [NleApiClient] constructor intentionally does NOT install the
  /// interceptor — that keeps mock-adapter-based unit tests of unrelated code
  /// from leaking entries into the global logger.
  factory NleApiClient.create({
    required String baseUrl,
    Map<String, String>? authHeaders,
    AppLogger? logger,
  }) {
    final effectiveLogger = logger ?? AppLogger.instance;
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
        headers: {...?authHeaders},
        // The NLE control API returns JSON and never legitimately redirects.
        // A 3xx means an access gate (Cloudflare Access, an SSO proxy)
        // intercepted the request — don't chase it into an HTML login page;
        // surface the 3xx so NleError.fromDio can classify it as an auth gate.
        followRedirects: false,
      ),
    );
    dio.interceptors.add(NleApiLoggingInterceptor(logger: effectiveLogger));
    effectiveLogger.info('auth: ${_authPresence(authHeaders)}');
    final hosted = isHostedBaseUrl(baseUrl);
    if (hosted) effectiveLogger.info('api: hosted v1');
    return NleApiClient(dio: dio, logger: effectiveLogger, hosted: hosted);
  }

  AppLogger get _log => _logger ?? AppLogger.instance;

  Future<DevicesResponse> getDevices() async {
    final raw = await fetchDevicesJson();
    return _parse(raw, () => DevicesResponse.fromJson(raw));
  }

  /// Same call as [getDevices] but returns the raw JSON body so callers (e.g.
  /// [PollingDeviceStateSource]) can cache it verbatim without re-serializing
  /// the parsed object graph. Throws [NleError] subclasses on HTTP failure;
  /// the body's shape isn't validated here (callers do that).
  Future<Map<String, dynamic>> fetchDevicesJson() async {
    if (hosted) return _hostedFetchDevicesJson();
    try {
      final response = await dio.get<Map<String, dynamic>>('/api/devices');
      return response.data!;
    } on DioException catch (e) {
      throw NleError.fromDio(e);
    }
  }

  /// Fetch the active schedule for [serial], or `null` if the server has none
  /// stored for that device. Per the Control API spec the endpoint always
  /// returns 200 with the response wrapped as
  /// `{serial, schedule, object_revision, object_timestamp}`; `schedule` is
  /// `null` when no schedule is stored.
  Future<Schedule?> getSchedule(String serial) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = hosted
          ? await dio.get<Map<String, dynamic>>(
              '/api/v1/thermostat/'
              '${Uri.encodeComponent(await _hostedIdFor(serial))}/schedule',
            )
          : await dio.get<Map<String, dynamic>>(
              '/api/schedule',
              queryParameters: {'serial': serial},
            );
    } on DioException catch (e) {
      throw NleError.fromDio(e);
    }
    final body = response.data;
    return _parse(body, () {
      final inner = body?['schedule'];
      if (inner is! Map<String, dynamic>) return null;
      return Schedule.fromJson(inner);
    });
  }

  /// Issue a write command per DESIGN §16.4. Body shape is
  /// `{serial, command, value}` posted to `/command`.
  ///
  /// On success, an `AppLogger.commandIssued` entry is appended via the
  /// underlying logger so the diagnostic log shows the command name + value
  /// (never any credential). HTTP-level metadata is also captured by the dio
  /// interceptor automatically.
  ///
  /// Retries once with a 2s backoff on transient failures (network errors and
  /// 5xx responses) per DESIGN §2.3. 4xx responses (validation/auth) are
  /// returned to the caller immediately — retrying won't help and the user
  /// needs the snackbar surface. Errors propagate as [NleError] subclasses.
  ///
  /// [retryDelay] is provided as an override for tests so they can run
  /// without waiting on real wall-clock time.
  Future<void> sendCommand({
    required String serial,
    required String command,
    required Object? value,
    Duration retryDelay = const Duration(seconds: 2),
  }) async {
    _log.commandIssued(command, value);
    final Future<void> Function() send;
    if (hosted) {
      final deviceId = await _hostedIdFor(serial);
      HostedRequest? req;
      try {
        req = hostedRequestFor(
          deviceId: deviceId,
          command: command,
          value: value,
          currentMode: _hostedModes[serial],
        );
      } on HostedUnsupportedCommand catch (e) {
        _log.info('hosted: skipped unsupported command $command');
        throw NleClientError(statusCode: 501, serverMessage: e.toString());
      }
      if (req == null) return;
      final r = req;
      send = () => dio.request<dynamic>(
        r.path,
        data: r.body,
        options: Options(method: r.method),
      );
    } else {
      final data = {'serial': serial, 'command': command, 'value': value};
      send = () => dio.post<dynamic>('/command', data: data);
    }
    try {
      await send();
      return;
    } on DioException catch (e) {
      if (!_isTransient(e)) throw NleError.fromDio(e);
      await Future<void>.delayed(retryDelay);
      try {
        await send();
      } on DioException catch (e2) {
        throw NleError.fromDio(e2);
      }
    }
  }

  /// Hosted mode: list devices, then fetch each device's status and reshape
  /// the whole thing into the self-hosted `/api/devices` body.
  Future<Map<String, dynamic>> _hostedFetchDevicesJson() async {
    try {
      final list = await dio.get<Map<String, dynamic>>('/api/v1/devices');
      final entries = (list.data?['devices'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final statuses = await Future.wait(
        entries.map(
          (e) => dio.get<Map<String, dynamic>>(
            '/api/v1/thermostat/'
            '${Uri.encodeComponent(e['id'] as String)}/status',
          ),
        ),
      );
      final devices = <Map<String, dynamic>>[];
      for (var i = 0; i < entries.length; i++) {
        final body = statuses[i].data ?? const <String, dynamic>{};
        final json = _parse(
          body,
          () => hostedStatusToDeviceJson(body, listEntry: entries[i]),
        );
        final serial = json['serial'] as String;
        _hostedIds[serial] = entries[i]['id'] as String;
        _hostedModes[serial] = json['mode'] as String;
        devices.add(json);
      }
      return {'devices': devices, 'total': devices.length};
    } on DioException catch (e) {
      throw NleError.fromDio(e);
    }
  }

  /// Hosted mode: the hosted device id for [serial], fetching the device list
  /// if it isn't cached yet.
  Future<String> _hostedIdFor(String serial) async {
    final cached = _hostedIds[serial];
    if (cached != null) return cached;
    try {
      final list = await dio.get<Map<String, dynamic>>('/api/v1/devices');
      for (final e in (list.data?['devices'] as List<dynamic>? ?? const [])) {
        if (e is Map<String, dynamic> && e['serial'] is String) {
          _hostedIds[e['serial'] as String] = e['id'] as String;
        }
      }
    } on DioException catch (e) {
      throw NleError.fromDio(e);
    }
    final id = _hostedIds[serial];
    if (id == null) {
      throw NleClientError(
        statusCode: 404,
        serverMessage: 'Device $serial not found on the hosted service.',
      );
    }
    return id;
  }

  static bool _isTransient(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.transformTimeout:
        return true;
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        return code >= 500 && code < 600;
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return false;
    }
  }

  /// Thin wrapper over [sendCommand] that posts a full schedule object as the
  /// `set_schedule` value. Schedule writes are full-replace per DESIGN §6.1.
  /// [scheduleMode] is the deliberate `schedule_mode` for the payload — see
  /// [Schedule.toJson]; when it differs from the device's shared-bucket value
  /// the caller must also issue [setScheduleMode] or the device ignores the
  /// schedule.
  Future<void> setSchedule(
    String serial,
    Schedule schedule, {
    required String scheduleMode,
  }) {
    return sendCommand(
      serial: serial,
      command: 'set_schedule',
      value: schedule.toJson(scheduleMode: scheduleMode),
    );
  }

  /// Set the device's shared-bucket `schedule_mode`. The value is the bare
  /// mode string per the Control API: one of `HEAT`/`COOL`/`RANGE`. The device
  /// ignores any schedule whose `schedule_mode` disagrees with this value, so
  /// the save path issues it before `set_schedule` whenever the two diverge.
  Future<void> setScheduleMode(String serial, String mode) {
    return sendCommand(
      serial: serial,
      command: 'set_schedule_mode',
      value: mode,
    );
  }

  /// Wrap a synchronous JSON-shaping callback so any thrown
  /// `FormatException`/`TypeError`/`NoSuchMethodError` becomes an
  /// [NleParseError] with a short excerpt logged for postmortem.
  T _parse<T>(Object? body, T Function() builder) {
    try {
      return builder();
    } catch (e) {
      final excerpt = _excerpt(body);
      _log.error('parse failed', data: {'excerpt': excerpt});
      throw NleParseError(responseExcerpt: excerpt, cause: e);
    }
  }

  static String _excerpt(Object? body) {
    final s = body?.toString() ?? '';
    return s.length <= 200 ? s : '${s.substring(0, 200)}…';
  }

  /// Maps the configured auth headers to a presence label
  /// (`"bearer"`/`"basic"`/`"cf-service-token"`/`"none"`/`"other"`) without
  /// leaking any credential value.
  static String _authPresence(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return 'none';
    if (headers.containsKey('CF-Access-Client-Id')) return 'cf-service-token';
    final auth = headers['Authorization']?.toLowerCase() ?? '';
    if (auth.startsWith('bearer')) return 'bearer';
    if (auth.startsWith('basic')) return 'basic';
    return 'other';
  }
}

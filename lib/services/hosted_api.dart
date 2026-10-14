/// Support for the **hosted** NoLongerEvil service (`https://nolongerevil.com`).
///
/// The rest of the app speaks the self-hosted Control API (`/api/devices`,
/// `/api/schedule`, `POST /command`). The hosted service exposes a different
/// surface (`/api/v1/devices`, `/api/v1/thermostat/{id}/...`) authenticated
/// with an `nle_` API key as a Bearer token. Rather than teach every screen
/// about two APIs, [NleApiClient] translates at its boundary: reads are
/// reshaped into the self-hosted JSON the models already parse, and
/// `/command` writes are routed to the matching hosted endpoint.
///
/// This file holds the pure (I/O-free) parts of that translation so they can
/// be unit-tested without a mock HTTP adapter.
library;

/// Hostname of the hosted service.
const String hostedHost = 'nolongerevil.com';

/// Canonical base URL for the hosted service, as produced by
/// `normalizeServerUrl`.
const String hostedBaseUrl = 'https://nolongerevil.com:443';

/// Whether [host] (no scheme/port) is the hosted NoLongerEvil service.
bool isHostedHost(String host) {
  final h = host.toLowerCase();
  return h == hostedHost || h == 'www.$hostedHost' || h == 'api.$hostedHost';
}

/// Whether [baseUrl] points at the hosted NoLongerEvil service.
bool isHostedBaseUrl(String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  if (uri == null) return false;
  return isHostedHost(uri.host);
}

/// Returns the bucket value map for the first `state` key starting with
/// `"$prefix."`, preferring the one keyed by [serial] when present.
Map<String, dynamic> _bucket(
  Map<String, dynamic> state,
  String prefix,
  String serial,
) {
  final exact = state['$prefix.$serial'];
  if (exact is Map<String, dynamic>) {
    final v = exact['value'];
    if (v is Map<String, dynamic>) return v;
  }
  for (final entry in state.entries) {
    if (entry.key.startsWith('$prefix.') && entry.value is Map) {
      final v = (entry.value as Map)['value'];
      if (v is Map<String, dynamic>) return v;
    }
  }
  return const {};
}

/// Largest `object_timestamp` (ms since epoch) across all buckets, or null.
int? _latestTimestamp(Map<String, dynamic> state) {
  int? latest;
  for (final v in state.values) {
    if (v is Map) {
      final ts = v['object_timestamp'];
      if (ts is num && (latest == null || ts > latest)) latest = ts.toInt();
    }
  }
  return latest;
}

double _num(Object? v, [double fallback = 0]) =>
    v is num ? v.toDouble() : fallback;

double? _numOrNull(Object? v) => v is num ? v.toDouble() : null;

int _int(Object? v, [int fallback = 0]) => v is num ? v.toInt() : fallback;

bool _bool(Object? v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  return fallback;
}

/// Converts one hosted `GET /api/v1/thermostat/{id}/status` response into the
/// self-hosted `/api/devices` per-device shape that `Device.fromJson` parses.
///
/// Mirrors `format_device_status` in NoLongerEvil-SelfHosted
/// (`routes/control/status.py`) so the two paths agree field-for-field.
/// Fields the hosted service does not expose fall back to safe defaults.
///
/// [listEntry] is the matching element of `GET /api/v1/devices`
/// (`{id, serial, name, accessType}`) and supplies the name/serial when the
/// status payload omits them.
Map<String, dynamic> hostedStatusToDeviceJson(
  Map<String, dynamic> status, {
  Map<String, dynamic>? listEntry,
}) {
  final deviceInfo = status['device'] is Map<String, dynamic>
      ? status['device'] as Map<String, dynamic>
      : const <String, dynamic>{};
  final serial =
      (deviceInfo['serial'] ?? listEntry?['serial'] ?? '') as String;
  final state = status['state'] is Map<String, dynamic>
      ? status['state'] as Map<String, dynamic>
      : const <String, dynamic>{};

  final shared = _bucket(state, 'shared', serial);
  final device = _bucket(state, 'device', serial);
  final structure = _bucket(state, 'structure', serial);
  final user = _bucket(state, 'user', serial);

  Object? pick(String key) => shared[key] ?? device[key];

  final name =
      (deviceInfo['name'] ??
              listEntry?['name'] ??
              shared['name'] ??
              device['name'])
          as String?;

  final latestMs = _latestTimestamp(state);
  final lastSeen = latestMs != null
      ? DateTime.fromMillisecondsSinceEpoch(latestMs, isUtc: true)
      : DateTime.now().toUtc();

  final fanTimerTimeout = _int(device['fan_timer_timeout']);
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // Eco/away: the self-hosted server reads `device.eco.mode`. If the hosted
  // payload doesn't carry the `eco` object, fall back to the structure/user
  // away flags the hosted `away` endpoint toggles.
  String? ecoMode;
  final eco = device['eco'];
  if (eco is Map && eco['mode'] is String) {
    ecoMode = eco['mode'] as String;
  } else {
    final awayFlag =
        _bool(structure['away']) ||
        _bool(user['away']) ||
        _bool(shared['away']);
    ecoMode = awayFlag ? 'manual-eco' : 'schedule';
  }

  final hasEco =
      device['away_temperature_high'] is num &&
      device['away_temperature_low'] is num;

  return <String, dynamic>{
    'serial': serial,
    // The hosted service authenticates the *client* with an nle_ key; the
    // per-device key the self-hosted server exposes isn't available.
    'api_key': '',
    'is_available': device['is_online'] is bool
        ? device['is_online'] as bool
        : true,
    'last_seen': lastSeen.toIso8601String(),
    'name': name,
    'current_temperature': _num(pick('current_temperature')),
    'target_temperature': _num(pick('target_temperature')),
    'target_temperature_high': _numOrNull(pick('target_temperature_high')),
    'target_temperature_low': _numOrNull(pick('target_temperature_low')),
    'humidity': _int(device['current_humidity']),
    'target_humidity': _num(device['target_humidity']),
    'target_humidity_enabled': _bool(device['target_humidity_enabled']),
    'mode': (pick('target_temperature_type') as String?) ?? 'off',
    'hvac': <String, dynamic>{
      'heater': _bool(shared['hvac_heater_state']),
      'heat_x2': _bool(shared['hvac_heat_x2_state']),
      'heat_x3': _bool(shared['hvac_heat_x3_state']),
      'ac': _bool(shared['hvac_ac_state']),
      'cool_x2': _bool(shared['hvac_cool_x2_state']),
      'cool_x3': _bool(shared['hvac_cool_x3_state']),
      'fan': _bool(shared['hvac_fan_state']),
      'aux_heat': _bool(shared['hvac_aux_heater_state']),
      'emer_heat': _bool(shared['hvac_emer_heat_state']),
      'alt_heat': _bool(shared['hvac_alt_heat_state']),
      'humidifier': _bool(device['humidifier_state']),
      'dehumidifier': _bool(device['dehumidifier_state']),
      'auto_dehum': _bool(device['auto_dehum_state']),
      'fan_cooling': _bool(device['fan_cooling_state']),
    },
    'fan_timer_active': fanTimerTimeout > nowSec,
    'fan_timer_timeout': fanTimerTimeout,
    'eco_temperatures': hasEco
        ? <String, dynamic>{
            'high': _num(device['away_temperature_high']),
            'low': _num(device['away_temperature_low']),
          }
        : null,
    'is_online': device['is_online'] is bool
        ? device['is_online'] as bool
        : true,
    'has_leaf': _bool(device['leaf'] ?? shared['leaf']),
    'software_version': (device['current_version'] as String?) ?? '',
    'temperature_scale': (device['temperature_scale'] as String?) ?? 'C',
    'capabilities': <String, dynamic>{
      'can_heat': _bool(pick('can_heat'), true),
      'can_cool': _bool(pick('can_cool'), true),
      'has_fan': _bool(pick('has_fan'), true),
      'has_emer_heat': _bool(pick('has_emer_heat')),
      'has_humidifier': _bool(pick('has_humidifier')),
      'has_dehumidifier': _bool(pick('has_dehumidifier')),
    },
    'eco_mode': ecoMode,
    'time_to_target': _int(device['time_to_target']),
    'backplate_temperature': _num(
      device['backplate_temperature'],
      _num(pick('current_temperature')),
    ),
    'structure_id': shared['structure_id'] as String?,
    'away': _bool(shared['away']),
    'schedule_mode': shared['schedule_mode'] as String?,
    'subscription_count': 0,
    'local_ip': device['local_ip'] as String?,
    'mac_address': device['mac_address'] as String?,
  };
}

/// A hosted v1 write: HTTP [method] to [path] with JSON [body].
class HostedRequest {
  final String method;
  final String path;
  final Map<String, dynamic> body;

  const HostedRequest(this.method, this.path, this.body);

  @override
  String toString() => '$method $path $body';
}

/// Thrown by [hostedRequestFor] when a self-hosted `/command` has no
/// equivalent on the hosted v1 API.
class HostedUnsupportedCommand implements Exception {
  final String command;
  const HostedUnsupportedCommand(this.command);

  @override
  String toString() =>
      'The hosted NoLongerEvil service does not support "$command".';
}

/// Maps a self-hosted `/command` ({command, value}) to the equivalent hosted
/// v1 request for device [deviceId].
///
/// [currentMode] is the device's last-known `mode` (`heat`/`cool`/`range`/…),
/// needed because hosted `POST .../temperature` requires an explicit
/// `heat`/`cool` mode while self-hosted `set_temperature` infers it.
///
/// Returns `null` for commands that are safe to skip on the hosted service
/// (currently `set_schedule_mode`, which the hosted schedule PUT carries
/// inside the schedule body). Throws [HostedUnsupportedCommand] for commands
/// with no hosted equivalent.
HostedRequest? hostedRequestFor({
  required String deviceId,
  required String command,
  required Object? value,
  String? currentMode,
}) {
  final base = '/api/v1/thermostat/${Uri.encodeComponent(deviceId)}';
  switch (command) {
    case 'set_temperature':
      if (value is Map) {
        return HostedRequest('POST', '$base/temperature/range', {
          'low': value['low'],
          'high': value['high'],
          'scale': 'C',
        });
      }
      final mode = currentMode == 'cool' ? 'cool' : 'heat';
      return HostedRequest('POST', '$base/temperature', {
        'value': value,
        'mode': mode,
        'scale': 'C',
      });
    case 'set_mode':
      final v = value == 'range' ? 'heat-cool' : value;
      if (v == 'emergency') throw HostedUnsupportedCommand('$command emergency');
      return HostedRequest('POST', '$base/mode', {'mode': v});
    case 'set_away':
      return HostedRequest('POST', '$base/away', {'away': value == true});
    case 'set_fan':
      if (value is num) {
        final secs = value.toInt().clamp(1, 43200);
        return HostedRequest('POST', '$base/fan', {'duration': secs});
      }
      return HostedRequest('POST', '$base/fan', {'mode': value});
    case 'set_schedule':
      return HostedRequest('PUT', '$base/schedule', {'schedule': value});
    case 'set_schedule_mode':
      return null;
    default:
      throw HostedUnsupportedCommand(command);
  }
}

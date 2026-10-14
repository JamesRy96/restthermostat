import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rest_thermostat/models/device.dart';
import 'package:rest_thermostat/services/hosted_api.dart';
import 'package:rest_thermostat/services/nle_api_client.dart';
import 'package:rest_thermostat/services/nle_error.dart';
import 'package:rest_thermostat/services/url_normalizer.dart';

const _serial = '02AA01AB01234567';
const _id = 'dev_abc123xyz';

/// Shape taken from the hosted docs' `GET /api/v1/thermostat/{id}/status`.
Map<String, dynamic> _status() => {
  'device': {'id': _id, 'serial': _serial, 'name': 'Living Room'},
  'state': {
    'shared.$_serial': {
      'object_revision': 152,
      'object_timestamp': 1764026373459,
      'value': {
        'target_temperature': 21.5,
        'target_temperature_type': 'heat',
        'current_temperature': 20.2,
        'hvac_heater_state': true,
        'hvac_ac_state': false,
        'fan_mode': 'auto',
        'auto_away': 0,
        'leaf': false,
        'can_cool': true,
        'can_heat': true,
      },
    },
    'device.$_serial': {
      'object_revision': 89,
      'object_timestamp': 1764026373000,
      'value': {
        'temperature_scale': 'F',
        'fan_timer_timeout': 0,
        'current_humidity': 41,
      },
    },
    'structure.95d0a01f-1c25-447f-ba61-edb275e9ae25': {
      'object_revision': -15172,
      'object_timestamp': 1764024645708,
      'value': {'name': 'Home', 'away': false},
    },
  },
};

void main() {
  group('hosted detection', () {
    test('recognizes the hosted service', () {
      expect(isHostedBaseUrl('https://nolongerevil.com:443'), isTrue);
      expect(isHostedBaseUrl('http://192.168.1.50:8082'), isFalse);
    });

    test('normalizeServerUrl maps hosted input to https:443', () {
      for (final input in [
        'nolongerevil.com',
        'http://nolongerevil.com',
        'https://nolongerevil.com/',
        'NoLongerEvil.com:8082',
        'https://nolongerevil.com/settings',
      ]) {
        expect(normalizeServerUrl(input), hostedBaseUrl, reason: input);
      }
    });
  });

  group('hostedStatusToDeviceJson', () {
    test('produces JSON that Device.fromJson accepts', () {
      final json = hostedStatusToDeviceJson(_status());
      final d = Device.fromJson(json);
      expect(d.serial, _serial);
      expect(d.name, 'Living Room');
      expect(d.mode, DeviceMode.heat);
      expect(d.currentTemperature, 20.2);
      expect(d.targetTemperature, 21.5);
      expect(d.temperatureScale, 'F');
      expect(d.humidity, 41);
      expect(d.hvac.heater, isTrue);
      expect(d.isAvailable, isTrue);
      expect(d.isAway, isFalse);
      expect(d.fanTimerActive, isFalse);
      expect(d.capabilities.canCool, isTrue);
    });

    test('reports away when structure.away is set', () {
      final s = _status();
      ((s['state'] as Map)['structure.95d0a01f-1c25-447f-ba61-edb275e9ae25']
              as Map)['value'] =
          {'away': true};
      expect(Device.fromJson(hostedStatusToDeviceJson(s)).isAway, isTrue);
    });

    test('prefers device.eco.mode when present', () {
      final s = _status();
      (((s['state'] as Map)['device.$_serial'] as Map)['value'] as Map)['eco'] =
          {'mode': 'manual-eco'};
      expect(Device.fromJson(hostedStatusToDeviceJson(s)).isAway, isTrue);
    });

    test('survives a nearly empty status', () {
      final json = hostedStatusToDeviceJson(
        {'device': {'id': _id, 'serial': _serial}, 'state': {}},
      );
      expect(() => Device.fromJson(json), returnsNormally);
    });
  });

  group('hostedRequestFor', () {
    HostedRequest? req(String c, Object? v, [String? mode]) => hostedRequestFor(
      deviceId: _id,
      command: c,
      value: v,
      currentMode: mode,
    );

    test('single setpoint uses current mode', () {
      final r = req('set_temperature', 22.0, 'cool')!;
      expect(r.path, '/api/v1/thermostat/$_id/temperature');
      expect(r.body, {'value': 22.0, 'mode': 'cool', 'scale': 'C'});
      expect(req('set_temperature', 22.0, 'heat')!.body['mode'], 'heat');
    });

    test('range setpoint goes to /temperature/range', () {
      final r = req('set_temperature', {'low': 19.0, 'high': 24.0})!;
      expect(r.path, '/api/v1/thermostat/$_id/temperature/range');
      expect(r.body, {'low': 19.0, 'high': 24.0, 'scale': 'C'});
    });

    test('mode, away, fan, schedule', () {
      expect(req('set_mode', 'heat-cool')!.body, {'mode': 'heat-cool'});
      expect(req('set_away', true)!.body, {'away': true});
      expect(req('set_fan', 'on')!.body, {'mode': 'on'});
      expect(req('set_fan', 900)!.body, {'duration': 900});
      final s = req('set_schedule', {'ver': 2})!;
      expect(s.method, 'PUT');
      expect(s.body, {
        'schedule': {'ver': 2},
      });
    });

    test('set_schedule_mode is skipped; eco temps unsupported', () {
      expect(req('set_schedule_mode', 'HEAT'), isNull);
      expect(
        () => req('set_eco_temperatures', {'low': 15, 'high': 28}),
        throwsA(isA<HostedUnsupportedCommand>()),
      );
    });
  });

  group('NleApiClient in hosted mode', () {
    late Dio dio;
    late DioAdapter adapter;
    late NleApiClient client;

    setUp(() {
      dio = Dio(BaseOptions(baseUrl: hostedBaseUrl));
      adapter = DioAdapter(dio: dio);
      client = NleApiClient(dio: dio, hosted: true);
      adapter
        ..onGet(
          '/api/v1/devices',
          (s) => s.reply(200, {
            'devices': [
              {
                'id': _id,
                'serial': _serial,
                'name': 'Living Room',
                'accessType': 'owner',
              },
            ],
          }),
        )
        ..onGet(
          '/api/v1/thermostat/$_id/status',
          (s) => s.reply(200, _status()),
        );
    });

    test('getDevices reshapes hosted responses', () async {
      final r = await client.getDevices();
      expect(r.total, 1);
      expect(r.devices.single.serial, _serial);
    });

    test('sendCommand routes set_temperature to hosted endpoint', () async {
      await client.getDevices();
      adapter.onPost(
        '/api/v1/thermostat/$_id/temperature',
        (s) => s.reply(200, {'success': true}),
        data: {'value': 20.0, 'mode': 'heat', 'scale': 'C'},
      );
      await client.sendCommand(
        serial: _serial,
        command: 'set_temperature',
        value: 20.0,
      );
    });

    test('unsupported command surfaces as NleClientError', () async {
      await client.getDevices();
      expect(
        () => client.sendCommand(
          serial: _serial,
          command: 'set_eco_temperatures',
          value: {'low': 15, 'high': 28},
        ),
        throwsA(isA<NleClientError>()),
      );
    });
  });
}

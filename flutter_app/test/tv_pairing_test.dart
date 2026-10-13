import 'package:flutter_app/services/tv_pairing.dart';
import 'package:flutter_app/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'abcdef0123456789abcdef0123456789abcdef0123456789';

void main() {
  test('QR carries only an approval token and canonical pairing address', () {
    final uri = Uri.parse(TvPairingLink.qrUrl(_token));
    expect(uri.scheme, 'https');
    expect(uri.host, 'iptv.florian-zug.de');
    expect(uri.path, '/tv/activate');
    expect(uri.query, isEmpty);
    expect(Uri.splitQueryString(uri.fragment), {'pairing_token': _token});
    expect(TvPairingLink.tryParse(uri.toString())?.token, _token);
  });

  test('known custom and OS-normalized routes keep the approval request', () {
    expect(
      TvPairingLink.tryParse(
        'streampilot://tv/activate?pairing_token=$_token',
      )?.token,
      _token,
    );
    expect(
      TvPairingLink.tryParse('/tv/activate#pairing_token=$_token')?.token,
      _token,
    );
    expect(
      TvPairingLink.tryParse('https://iptv.florian-zug.de/tv/activate')?.token,
      isNull,
    );
    expect(
      TvPairingLink.tryParse('https://iptv.florian-zug.de/tv/activate'),
      isNotNull,
    );
  });

  test(
    'foreign hosts, injected origins, duplicate and malformed tokens are rejected',
    () {
      for (final url in [
        'https://example.test/tv/activate#pairing_token=$_token',
        'http://iptv.florian-zug.de/tv/activate#pairing_token=$_token',
        'https://iptv.florian-zug.de.evil.test/tv/activate#pairing_token=$_token',
        'streampilot://other/activate?pairing_token=$_token',
        '/tv/activate#pairing_token=short',
        '/tv/activate?pairing_token=$_token#pairing_token=$_token',
        '/tv/activate#pairing_token=$_token&api_base=https://example.test',
      ]) {
        expect(TvPairingLink.tryParse(url), isNull);
      }
    },
  );

  test('session rejects malformed data and parses the server expiry', () {
    final session = TvPairingSession.fromJson({
      'user_code': '123456',
      'expires_at': '2030-01-01T12:00:00Z',
      'status': 'pending',
      'device_name': 'Living room TV',
    });
    expect(session.userCode, '123456');
    expect(session.deviceName, 'Living room TV');
    expect(session.expiresAt, DateTime.utc(2030, 1, 1, 12));
    expect(
      () => TvPairingSession.fromJson({'status': 'pending'}),
      throwsA(isA<ApiException>()),
    );
  });
}

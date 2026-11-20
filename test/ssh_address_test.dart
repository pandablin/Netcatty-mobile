import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';

void main() {
  group('bareHostname', () {
    test('strips brackets around IPv6 literals', () {
      expect(bareHostname('[2001:db8::1]'), '2001:db8::1');
      expect(bareHostname(' [::1] '), '::1');
    });

    test('leaves other hosts untouched', () {
      expect(bareHostname('example.com'), 'example.com');
      expect(bareHostname('10.0.0.1'), '10.0.0.1');
      expect(bareHostname('2001:db8::1'), '2001:db8::1');
    });
  });

  group('hostAuthority', () {
    test('brackets IPv6 literals for HTTP CONNECT', () {
      expect(hostAuthority('2001:db8::1', 22), '[2001:db8::1]:22');
      expect(hostAuthority('[2001:db8::1]', 2222), '[2001:db8::1]:2222');
    });

    test('keeps IPv4 and domain names as host:port', () {
      expect(hostAuthority('10.0.0.1', 22), '10.0.0.1:22');
      expect(hostAuthority('example.com', 22), 'example.com:22');
    });
  });

  group('socksAddress', () {
    test('encodes IPv4 literals as ATYP 1', () {
      expect(socksAddress('192.168.1.2'), [1, 192, 168, 1, 2]);
    });

    test('encodes IPv6 literals as ATYP 4', () {
      final encoded = socksAddress('[::1]');
      expect(encoded.first, 4);
      expect(encoded.length, 17);
      expect(encoded.last, 1);
    });

    test('encodes domain names as ATYP 3', () {
      expect(socksAddress('ab.c'), [3, 4, 97, 98, 46, 99]);
    });
  });
}

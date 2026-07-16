import 'dart:convert';

import 'package:b8im_app_flutter/src/security/canonical_json.dart';
import 'package:b8im_app_flutter/src/security/routing_signature_verifier.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

void main() {
  test('验证 Ed25519 规范化线路签名并拒绝篡改', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final payload = <String, Object?>{
      'organization': 1,
      'client_family': 'app',
      'server_info': {
        'routes': [
          {'route_id': 'primary', 'priority': 10},
        ],
        'schema_version': 2,
      },
    };
    final signature = await algorithm.sign(
      utf8.encode(canonicalJson(payload)),
      keyPair: keyPair,
    );
    final verifier = RoutingSignatureVerifier({
      'test-key': _base64Url(publicKey.bytes),
    });
    final contract = {
      'alg': 'Ed25519',
      'kid': 'test-key',
      'canonicalization': 'JCS-RFC8785',
      'value': _base64Url(signature.bytes),
    };

    await verifier.verify(payload: payload, signatureValue: contract);

    final tampered = {...payload, 'organization': 2};
    await expectLater(
      verifier.verify(payload: tampered, signatureValue: contract),
      throwsFormatException,
    );
  });
}

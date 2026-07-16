import 'package:b8im_app_flutter/src/config/app_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('官方默认发现入口包含配套的线路签名信任根', () {
    final environment = AppEnvironment.fromCompileTime();

    expect(environment.discoveryBaseUri, Uri.parse('https://api.idev.love'));
    expect(
      environment.routingPublicKeys['routing-test-20260713'],
      'zmCoq_5gBvehkWdyhSloXZJVHU_nbpZ16ySHJvNKUo8',
    );
  });
}

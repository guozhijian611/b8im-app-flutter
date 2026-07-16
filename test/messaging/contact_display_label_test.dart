import 'package:b8im_app_flutter/src/messaging/contact_display_label.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('same-org omits company suffix', () {
    expect(
      ContactDisplayLabel.format(
        nickname: '张三',
        account: 'zhangsan',
        companyName: 'XX科技',
        isCrossOrganization: false,
      ),
      '张三',
    );
  });

  test('cross-org appends company suffix', () {
    expect(
      ContactDisplayLabel.format(
        nickname: '张三',
        account: 'zhangsan',
        companyName: 'XX科技',
        isCrossOrganization: true,
      ),
      '张三 · XX科技',
    );
  });

  test('prefers server display_name when provided', () {
    expect(
      ContactDisplayLabel.format(
        nickname: '张三',
        account: 'zhangsan',
        companyName: 'YY',
        isCrossOrganization: true,
        serverDisplayName: '张三 · XX科技',
      ),
      '张三 · XX科技',
    );
  });

  test('falls back to account when nickname empty', () {
    expect(
      ContactDisplayLabel.format(
        nickname: '',
        account: 'bob2',
        companyName: 'Org2',
        isCrossOrganization: true,
      ),
      'bob2 · Org2',
    );
  });
}

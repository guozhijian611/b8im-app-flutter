import 'package:b8im_app_flutter/src/observability/trace_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('生成并继续合法 W3C traceparent', () {
    final root = TraceContext.root();
    final parsed = TraceContext.parse(root.traceparent);
    final child = parsed.child();

    expect(
      root.traceparent,
      matches(RegExp(r'^00-[0-9a-f]{32}-[0-9a-f]{16}-01$')),
    );
    expect(child.traceId, root.traceId);
    expect(child.spanId, isNot(root.spanId));
    expect(child.injectHttp()['traceparent'], child.traceparent);
    expect(
      child.injectImEnvelope({'cmd': 'AUTH'})['traceparent'],
      child.traceparent,
    );
  });

  test('拒绝全零或结构错误的 traceparent', () {
    expect(
      () => TraceContext.parse(
        '00-00000000000000000000000000000000-0000000000000000-01',
      ),
      throwsFormatException,
    );
    expect(() => TraceContext.parse('invalid'), throwsFormatException);
  });
}

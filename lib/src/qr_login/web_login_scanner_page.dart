import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../discovery/tenant_config.dart';
import '../network/app_api_client.dart';
import '../session/app_session.dart';
import 'app_qr_login_service.dart';
import 'web_login_qr_payload.dart';

enum AppQrScannerErrorKind { permissionDenied, unavailable }

final class AppQrScannerException implements Exception {
  const AppQrScannerException(this.kind, this.message);

  final AppQrScannerErrorKind kind;
  final String message;

  @override
  String toString() => message;
}

abstract interface class AppQrCodeScanner {
  Widget buildPreview({
    required ValueChanged<String> onDetect,
    required ValueChanged<AppQrScannerException> onError,
  });

  Future<void> start();

  Future<void> stop();

  Future<void> dispose();
}

typedef AppQrCodeScannerFactory = AppQrCodeScanner Function();

final class MobileAppQrCodeScanner implements AppQrCodeScanner {
  MobileAppQrCodeScanner()
    : _controller = MobileScannerController(
        autoStart: false,
        formats: const [BarcodeFormat.qrCode],
      );

  final MobileScannerController _controller;
  AppQrScannerErrorKind? _lastReportedError;

  @override
  Widget buildPreview({
    required ValueChanged<String> onDetect,
    required ValueChanged<AppQrScannerException> onError,
  }) {
    return MobileScanner(
      key: const ValueKey('web-login-camera-preview'),
      controller: _controller,
      fit: BoxFit.cover,
      onDetect: (capture) {
        for (final barcode in capture.barcodes) {
          final value = barcode.rawValue;
          if (barcode.format == BarcodeFormat.qrCode &&
              value != null &&
              value.isNotEmpty) {
            onDetect(value);
            return;
          }
        }
      },
      onDetectError: (error, _) {
        onError(_scannerException(error));
      },
      errorBuilder: (context, error) {
        final scannerError = _scannerException(error);
        if (_lastReportedError != scannerError.kind) {
          _lastReportedError = scannerError.kind;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            onError(scannerError);
          });
        }
        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                scannerError.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        );
      },
      placeholderBuilder: (_) => const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      ),
    );
  }

  @override
  Future<void> start() async {
    _lastReportedError = null;
    try {
      await _controller.start();
    } on MobileScannerException catch (error) {
      if (error.errorCode ==
          MobileScannerErrorCode.controllerAlreadyInitialized) {
        return;
      }
      throw _scannerException(error);
    }
  }

  @override
  Future<void> stop() => _controller.stop();

  @override
  Future<void> dispose() => _controller.dispose();

  static AppQrScannerException _scannerException(Object error) {
    if (error is MobileScannerException &&
        error.errorCode == MobileScannerErrorCode.permissionDenied) {
      return const AppQrScannerException(
        AppQrScannerErrorKind.permissionDenied,
        '相机权限已被拒绝，请在系统设置中允许 b8im 使用相机',
      );
    }
    if (error is MobileScannerException &&
        error.errorCode == MobileScannerErrorCode.unsupported) {
      return const AppQrScannerException(
        AppQrScannerErrorKind.unavailable,
        '当前设备没有可用相机，无法扫描二维码',
      );
    }
    return const AppQrScannerException(
      AppQrScannerErrorKind.unavailable,
      '相机暂时不可用，请稍后重试',
    );
  }
}

final class WebLoginScannerPage extends StatefulWidget {
  const WebLoginScannerPage({
    super.key,
    required this.tenant,
    required this.session,
    required this.gateway,
    this.scanner,
  });

  final TenantConfig tenant;
  final AppSession session;
  final AppQrLoginGateway gateway;
  final AppQrCodeScanner? scanner;

  @override
  State<WebLoginScannerPage> createState() => _WebLoginScannerPageState();
}

final class _WebLoginScannerPageState extends State<WebLoginScannerPage>
    with WidgetsBindingObserver {
  late final AppQrCodeScanner _scanner;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  String? _error;
  bool _processing = false;
  bool _starting = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _scanner = widget.scanner ?? MobileAppQrCodeScanner();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startScanner());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      unawaited(_startScanner());
    } else {
      unawaited(_stopScanner());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_closeScanner());
    super.dispose();
  }

  Future<void> _closeScanner() async {
    await _stopScanner();
    await _scanner.dispose();
  }

  bool get _canRun =>
      mounted &&
      !_processing &&
      _error == null &&
      _lifecycleState == AppLifecycleState.resumed;

  Future<void> _startScanner() async {
    if (!_canRun || _running || _starting) return;
    _starting = true;
    try {
      await _scanner.start();
      if (_canRun) {
        _running = true;
      } else {
        await _scanner.stop();
      }
    } on AppQrScannerException catch (error) {
      _showScannerError(error);
    } on Object {
      _showScannerError(
        const AppQrScannerException(
          AppQrScannerErrorKind.unavailable,
          '相机暂时不可用，请稍后重试',
        ),
      );
    } finally {
      _starting = false;
    }
  }

  Future<void> _stopScanner() async {
    _running = false;
    try {
      await _scanner.stop();
    } on Object {
      // 页面正在离开或相机尚未完成初始化时，关闭操作无需打断用户流程。
    }
  }

  void _showScannerError(AppQrScannerException error) {
    if (!mounted) return;
    _running = false;
    setState(() {
      _processing = false;
      _error = error.message;
    });
  }

  Future<void> _handleCode(String value) async {
    if (_processing || _error != null) return;
    setState(() => _processing = true);
    await _stopScanner();
    try {
      final payload = WebLoginQrPayload.parse(value, widget.tenant);
      final scan = await widget.gateway.scan(
        tenant: widget.tenant,
        session: widget.session,
        payload: payload,
      );
      if (!mounted) return;
      final confirmed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => WebLoginConfirmPage(
            tenant: widget.tenant,
            session: widget.session,
            gateway: widget.gateway,
            scan: scan,
          ),
        ),
      );
      if (!mounted) return;
      if (confirmed == true) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() => _processing = false);
      await _startScanner();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = _scanErrorMessage(error);
      });
    }
  }

  Future<void> _retry() async {
    setState(() {
      _error = null;
      _processing = false;
    });
    await _startScanner();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('扫一扫'),
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _scanner.buildPreview(
              onDetect: (value) => unawaited(_handleCode(value)),
              onError: _showScannerError,
            ),
            IgnorePointer(
              child: Center(
                child: Container(
                  key: const ValueKey('web-login-scan-window'),
                  width: 250,
                  height: 250,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 3),
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 32,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_processing) ...[
                        const CircularProgressIndicator(color: Colors.white),
                        const SizedBox(height: 12),
                        const Text(
                          '正在校验二维码…',
                          style: TextStyle(color: Colors.white),
                        ),
                      ] else if (_error case final error?) ...[
                        Text(
                          error,
                          key: const ValueKey('web-login-scan-error'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          key: const ValueKey('web-login-scan-retry'),
                          onPressed: _retry,
                          child: const Text('重新扫描'),
                        ),
                      ] else
                        const Text(
                          '将 Web 登录二维码放入框内',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class WebLoginConfirmPage extends StatefulWidget {
  const WebLoginConfirmPage({
    super.key,
    required this.tenant,
    required this.session,
    required this.gateway,
    required this.scan,
  });

  final TenantConfig tenant;
  final AppSession session;
  final AppQrLoginGateway gateway;
  final WebLoginScanResult scan;

  @override
  State<WebLoginConfirmPage> createState() => _WebLoginConfirmPageState();
}

final class _WebLoginConfirmPageState extends State<WebLoginConfirmPage> {
  Timer? _timer;
  String? _error;
  bool _confirming = false;

  bool get _expired => !widget.scan.expiresAt.isAfter(DateTime.now().toUtc());

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_confirming || _expired) return;
    setState(() {
      _confirming = true;
      _error = null;
    });
    try {
      await widget.gateway.confirm(
        tenant: widget.tenant,
        session: widget.session,
        qrId: widget.scan.qrId,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _confirmErrorMessage(error));
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.scan.expiresAt.difference(DateTime.now().toUtc());
    final remainingSeconds = remaining.inSeconds.clamp(0, 9999);
    return Scaffold(
      appBar: AppBar(title: const Text('确认 Web 登录')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          children: [
            const CircleAvatar(
              radius: 34,
              child: Icon(Icons.computer_rounded, size: 34),
            ),
            const SizedBox(height: 22),
            Text(
              '登录 ${widget.scan.organizationName}',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              widget.scan.webOrigin.origin,
              key: const ValueKey('web-login-site'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 28),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    _ConfirmDetail(
                      label: '当前账号',
                      value: widget.session.user.nickname,
                    ),
                    const Divider(height: 28),
                    _ConfirmDetail(
                      label: '浏览器设备',
                      value: widget.scan.browserDevice,
                    ),
                    const Divider(height: 28),
                    _ConfirmDetail(
                      label: '二维码有效期',
                      value: _expired ? '已过期' : '剩余 $remainingSeconds 秒',
                      valueKey: const ValueKey('web-login-expiry'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '仅在确认后 Web 才会登录；App 登录凭据不会发送给 Web。',
              textAlign: TextAlign.center,
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 18),
              Text(
                error,
                key: const ValueKey('web-login-confirm-error'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_expired) ...[
              const SizedBox(height: 18),
              Text(
                '二维码已过期，请返回重新扫描',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 28),
            FilledButton(
              key: const ValueKey('web-login-confirm'),
              onPressed: _confirming || _expired ? null : _confirm,
              child: _confirming
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('确认登录'),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              key: const ValueKey('web-login-cancel'),
              onPressed: _confirming
                  ? null
                  : () => Navigator.of(context).pop(false),
              child: Text(_error == null && !_expired ? '取消' : '重新扫描'),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ConfirmDetail extends StatelessWidget {
  const _ConfirmDetail({
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            key: valueKey,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

String _scanErrorMessage(Object error) {
  if (error is FormatException) return error.message;
  if (error is AppApiException) {
    if (_matchesApiError(error, const {400, 403, 404, 409, 410, 422})) {
      return error.message;
    }
    if (_matchesApiError(error, const {401})) return '登录状态已失效，请重新登录';
  }
  return '二维码校验失败，请检查网络后重新扫描';
}

String _confirmErrorMessage(Object error) {
  if (error is FormatException) return error.message;
  if (error is AppApiException) {
    if (_matchesApiError(error, const {400, 403, 404, 409, 410, 422})) {
      return error.message;
    }
    if (_matchesApiError(error, const {401})) return '登录状态已失效，请重新登录';
  }
  return '确认失败，请检查网络后重试';
}

bool _matchesApiError(AppApiException error, Set<int> codes) =>
    (error.statusCode != null && codes.contains(error.statusCode)) ||
    (error.code != null && codes.contains(error.code));

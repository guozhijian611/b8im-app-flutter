import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

import 'app_media_service.dart';

final class AppPickedMedia {
  const AppPickedMedia({
    required this.kind,
    required this.path,
    required this.filename,
    required this.size,
    required this.mimeType,
  });

  final AppMediaKind kind;
  final String path;
  final String filename;
  final int size;
  final String mimeType;
}

abstract interface class AppMediaPickerGateway {
  Future<AppPickedMedia?> pick(AppMediaKind kind);
}

final class DeviceAppMediaPicker implements AppMediaPickerGateway {
  DeviceAppMediaPicker({ImagePicker? imagePicker})
    : _imagePicker = imagePicker ?? ImagePicker();

  final ImagePicker _imagePicker;

  @override
  Future<AppPickedMedia?> pick(AppMediaKind kind) async {
    final path = switch (kind) {
      AppMediaKind.image => (await _imagePicker.pickImage(
        source: ImageSource.gallery,
      ))?.path,
      AppMediaKind.file => (await openFile())?.path,
    };
    if (path == null) return null;
    final file = File(path);
    final filename = file.uri.pathSegments.last;
    final size = await file.length();
    final fallbackMime = kind == AppMediaKind.image
        ? 'image/jpeg'
        : 'application/octet-stream';
    return AppPickedMedia(
      kind: kind,
      path: path,
      filename: filename,
      size: size,
      mimeType: lookupMimeType(path) ?? fallbackMime,
    );
  }
}

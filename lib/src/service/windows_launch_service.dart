import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:window_manager/window_manager.dart';

import '../enum/config_enum.dart';
import '../model/gallery_image.dart';
import '../model/gallery_url.dart';
import '../model/read_page_info.dart';
import '../pages/details/details_page_logic.dart';
import '../routes/routes.dart';
import '../utils/file_util.dart';
import '../utils/route_util.dart' as route;
import '../utils/toast_util.dart';
import 'gallery_download/gallery_download_service.dart';
import 'local_config_service.dart';
import 'log.dart';
import 'path_service.dart';

/// Windows-only bridge used by external library managers such as Bakabase.
///
/// Supported invocation forms:
///   jhentai.exe "D:\\Comics\\Gallery\\001.jpg"
///   jhentai.exe "D:\\Comics\\Gallery"
///   jhentai.exe --open "D:\\Comics\\Gallery\\001.jpg"
///   jhentai.exe "https://e-hentai.org/g/123/token/"
///
/// The first custom JHenTai instance listens on loopback. Later invocations
/// with an open target forward the target to that instance and exit, so using
/// JHenTai from Bakabase does not create another reader window every time.
WindowsLaunchService windowsLaunchService = WindowsLaunchService();

class WindowsLaunchService {
  static const int _bridgePort = 47631;
  static const Duration _ipcTimeout = Duration(milliseconds: 800);

  ServerSocket? _server;
  bool _appReady = false;
  final List<String> _pendingTargets = <String>[];

  /// Prepare the Windows launch bridge before Flutter starts.
  ///
  /// Returns true when this process only forwarded an open request to an
  /// already-running custom JHenTai instance and should exit immediately.
  Future<bool> prepare(List<String> args) async {
    if (!Platform.isWindows) {
      return false;
    }

    final String? target = _extractTarget(args);

    try {
      _server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _bridgePort,
        shared: false,
      );
      _server!.listen(
        _handleClient,
        onError: (Object error, StackTrace stackTrace) {
          _reportError('Windows launch bridge listener error', error, stackTrace);
        },
      );

      if (target != null) {
        _pendingTargets.add(target);
      }
      return false;
    } on SocketException catch (e, st) {
      // The normal case is another custom JHenTai instance already owning the
      // loopback port. Only treat it as such when that instance acknowledges
      // our request; a random local port collision must not swallow the launch.
      if (target != null && await _forwardTarget(target)) {
        return true;
      }

      _reportError('Unable to own Windows launch bridge port', e, st);
      if (target != null) {
        _pendingTargets.add(target);
      }
      return false;
    }
  }

  /// Called once GetMaterialApp has a navigator and JHenTai services are ready.
  Future<void> onAppReady() async {
    if (!Platform.isWindows) {
      return;
    }

    _appReady = true;
    if (_pendingTargets.isEmpty) {
      return;
    }

    final List<String> targets = List<String>.of(_pendingTargets);
    _pendingTargets.clear();
    for (final String target in targets) {
      await _openWhenUnlocked(target);
    }
  }

  String? _extractTarget(List<String> args) {
    if (args.isEmpty) {
      return null;
    }

    int index = 0;
    if (args.first == '--open' || args.first == '--path' || args.first == '--url') {
      index = 1;
    }
    if (index >= args.length) {
      return null;
    }

    String target = args[index].trim();
    if (target.length >= 2 &&
        ((target.startsWith('"') && target.endsWith('"')) ||
            (target.startsWith("'") && target.endsWith("'")))) {
      target = target.substring(1, target.length - 1);
    }

    return target.isEmpty ? null : target;
  }

  Future<bool> _forwardTarget(String target) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _bridgePort,
        timeout: _ipcTimeout,
      );
      socket.writeln(jsonEncode(<String, String>{'type': 'open', 'target': target}));
      await socket.flush();

      final String response = await socket
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(_ipcTimeout);
      return response == 'OK';
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _handleClient(Socket socket) async {
    try {
      final String line = await socket
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 2));
      final Object? decoded = jsonDecode(line);
      if (decoded is! Map || decoded['type'] != 'open' || decoded['target'] is! String) {
        socket.writeln('ERR');
        await socket.flush();
        return;
      }

      final String target = (decoded['target'] as String).trim();
      if (target.isEmpty) {
        socket.writeln('ERR');
        await socket.flush();
        return;
      }

      socket.writeln('OK');
      await socket.flush();

      if (_appReady) {
        unawaited(_openWhenUnlocked(target));
      } else {
        _pendingTargets.add(target);
      }
    } catch (e, st) {
      _reportError('Invalid Windows launch bridge request', e, st);
      try {
        socket.writeln('ERR');
        await socket.flush();
      } catch (_) {}
    } finally {
      socket.destroy();
    }
  }

  Future<void> _openWhenUnlocked(String target) async {
    // Never jump past JHenTai's password/biometric lock screen. Keep the
    // external request pending until the user finishes unlocking.
    while (Get.currentRoute == Routes.lock) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await _openTarget(target);
  }

  Future<void> _openTarget(String target) async {
    await _bringWindowToFront();

    final GalleryUrl? galleryUrl = GalleryUrl.tryParse(target);
    if (galleryUrl != null) {
      _openGalleryUrl(galleryUrl);
      return;
    }

    final _ResolvedLocalGallery? gallery = _resolveLocalGallery(target);
    if (gallery == null) {
      toast('Unable to open gallery path: $target', isShort: false);
      return;
    }

    String? savedIndexRaw;
    try {
      savedIndexRaw = await localConfigService.read(
        configKey: ConfigEnum.readIndexRecord,
        subConfigKey: gallery.progressKey,
      );
    } catch (e, st) {
      _reportError('Unable to read external gallery progress', e, st);
    }

    int initialIndex = int.tryParse(savedIndexRaw ?? '') ?? gallery.targetImageIndex;
    if (initialIndex < 0 || initialIndex >= gallery.images.length) {
      initialIndex = 0;
    }

    final ReadPageInfo info = ReadPageInfo(
      mode: ReadMode.local,
      galleryTitle: gallery.title,
      initialIndex: initialIndex,
      pageCount: gallery.images.length,
      readProgressRecordStorageKey: gallery.progressKey,
      images: gallery.images,
      useSuperResolution: false,
    );

    // Read is a full-screen route. Replace an existing reader instead of
    // stacking a second reader on top; otherwise use the normal adaptive route
    // helper so launch behaviour stays identical to JHenTai's local gallery UI.
    if (Get.currentRoute == Routes.read) {
      Get.offNamed(
        Routes.read,
        arguments: info,
        preventDuplicates: false,
      );
    } else {
      route.toRoute(
        Routes.read,
        arguments: info,
        preventDuplicates: false,
      );
    }
  }

  void _openGalleryUrl(GalleryUrl galleryUrl) {
    if (Get.currentRoute == Routes.read) {
      Get.back();
    }

    route.toRoute(
      Routes.details,
      arguments: DetailsPageArgument(galleryUrl: galleryUrl),
      offAllBefore: false,
      preventDuplicates: false,
    );
  }

  _ResolvedLocalGallery? _resolveLocalGallery(String target) {
    final FileSystemEntityType type;
    try {
      type = FileSystemEntity.typeSync(target, followLinks: true);
    } catch (e, st) {
      _reportError('Unable to inspect external gallery path: $target', e, st);
      return null;
    }

    late final Directory galleryDirectory;
    String? requestedImagePath;
    if (type == FileSystemEntityType.file) {
      final File file = File(target).absolute;
      galleryDirectory = file.parent;
      if (FileUtil.isImageExtension(file.path)) {
        requestedImagePath = path.normalize(file.path);
      }
    } else if (type == FileSystemEntityType.directory) {
      galleryDirectory = Directory(target).absolute;
    } else {
      return null;
    }

    final List<File> imageFiles;
    try {
      imageFiles = galleryDirectory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((File file) => FileUtil.isImageExtension(file.path))
          .toList()
        ..sort(FileUtil.naturalCompareFile);
    } catch (e, st) {
      _reportError('Unable to enumerate external gallery: ${galleryDirectory.path}', e, st);
      return null;
    }

    if (imageFiles.isEmpty) {
      return null;
    }

    final String visibleRoot = pathService.getVisibleDir().path;
    final List<GalleryImage> images = imageFiles
        .map(
          (File file) => GalleryImage(
            url: '',
            path: path.relative(file.path, from: visibleRoot),
            downloadStatus: DownloadStatus.downloaded,
          ),
        )
        .toList(growable: false);

    int targetImageIndex = 0;
    if (requestedImagePath != null) {
      final String normalizedRequested = requestedImagePath.toLowerCase();
      final int index = imageFiles.indexWhere(
        (File file) => path.normalize(file.absolute.path).toLowerCase() == normalizedRequested,
      );
      if (index >= 0) {
        targetImageIndex = index;
      }
    }

    return _ResolvedLocalGallery(
      title: path.basename(galleryDirectory.path),
      images: images,
      progressKey: images.first.path!,
      targetImageIndex: targetImageIndex,
    );
  }

  Future<void> _bringWindowToFront() async {
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
    } catch (e, st) {
      // Navigation is still useful even if Windows refuses a focus request.
      _reportError('Unable to focus JHenTai window for external launch', e, st);
    }
  }

  void _reportError(String message, Object error, [StackTrace? stackTrace]) {
    if (_appReady) {
      log.error(message, error, stackTrace);
      return;
    }

    // prepare() runs before JHenTai's PathService/LogService lifecycle. Using
    // the normal logger here would itself touch uninitialized paths.
    stderr.writeln('$message: $error');
    if (stackTrace != null) {
      stderr.writeln(stackTrace);
    }
  }
}

class _ResolvedLocalGallery {
  final String title;
  final List<GalleryImage> images;
  final String progressKey;
  final int targetImageIndex;

  const _ResolvedLocalGallery({
    required this.title,
    required this.images,
    required this.progressKey,
    required this.targetImageIndex,
  });
}

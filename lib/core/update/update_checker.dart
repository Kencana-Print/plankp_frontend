import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../constants/app_constants.dart';

enum AppUpdateStatus {
  upToDate,
  updateAvailable,
  failedCheck,
}

class AppUpdateManifest {
  final String version;
  final int buildNumber;
  final bool mandatory;
  final String? notes;
  final String? pubDate;
  final String url;
  final String? sha256;

  const AppUpdateManifest({
    required this.version,
    required this.buildNumber,
    required this.mandatory,
    required this.url,
    this.notes,
    this.pubDate,
    this.sha256,
  });

  factory AppUpdateManifest.fromJson(Map<String, dynamic> json) {
    final rawBuild = json['buildNumber'] ?? json['versionCode'];
    final parsedBuild = rawBuild is int
        ? rawBuild
        : int.tryParse(rawBuild?.toString() ?? '') ?? 0;

    final versionValue =
        (json['version'] ?? json['versionName'] ?? '').toString();
    final urlValue = (json['url'] ?? json['apkUrl'] ?? '').toString();

    return AppUpdateManifest(
      version: versionValue,
      buildNumber: parsedBuild,
      mandatory: json['mandatory'] == true,
      notes: json['notes']?.toString(),
      pubDate: (json['pub_date'] ?? json['releaseDate'])?.toString(),
      url: urlValue,
      sha256: json['sha256']?.toString(),
    );
  }
}

class AppUpdateCheckResult {
  final AppUpdateStatus status;
  final AppUpdateManifest? manifest;
  final String currentVersion;
  final int currentBuildNumber;

  const AppUpdateCheckResult({
    required this.status,
    required this.currentVersion,
    required this.currentBuildNumber,
    this.manifest,
  });

  bool get hasUpdate => status == AppUpdateStatus.updateAvailable;
}

class UpdateChecker {
  final http.Client _httpClient;
  final String _manifestUrl;

  UpdateChecker({
    http.Client? httpClient,
    String? manifestUrl,
  })  : _httpClient = httpClient ?? http.Client(),
        _manifestUrl = manifestUrl ?? ApiConfig.updateManifestUrl;

  Future<AppUpdateCheckResult> checkForUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

    try {
      final response = await _httpClient.get(
        Uri.parse(_manifestUrl),
        headers: const {'Accept': 'application/json'},
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return AppUpdateCheckResult(
          status: AppUpdateStatus.failedCheck,
          currentVersion: packageInfo.version,
          currentBuildNumber: currentBuild,
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return AppUpdateCheckResult(
          status: AppUpdateStatus.upToDate,
          currentVersion: packageInfo.version,
          currentBuildNumber: currentBuild,
        );
      }

      final manifest = AppUpdateManifest.fromJson(decoded);
      final hasRequiredFields =
          manifest.version.isNotEmpty && manifest.url.isNotEmpty;

      if (!hasRequiredFields || manifest.buildNumber <= currentBuild) {
        return AppUpdateCheckResult(
          status: AppUpdateStatus.upToDate,
          currentVersion: packageInfo.version,
          currentBuildNumber: currentBuild,
        );
      }

      return AppUpdateCheckResult(
        status: AppUpdateStatus.updateAvailable,
        manifest: manifest,
        currentVersion: packageInfo.version,
        currentBuildNumber: currentBuild,
      );
    } catch (_) {
      return AppUpdateCheckResult(
        status: AppUpdateStatus.failedCheck,
        currentVersion: packageInfo.version,
        currentBuildNumber: currentBuild,
      );
    }
  }

  static int? _runningWebBuildNumber;
  static String? _runningWebVersion;

  /// Khusus Flutter Web: Cek apakah versi di server web lebih tinggi daripada versi yang sedang dibuka user.
  Future<AppUpdateCheckResult> checkWebUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
    final currentVersion = packageInfo.version;

    // Inisialisasi versi runtime aplikasi web saat pertama kali dimuat
    if (_runningWebBuildNumber == null && currentBuild > 0) {
      _runningWebBuildNumber = currentBuild;
      _runningWebVersion = currentVersion;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Cek ke /version.json bawaan Flutter Web di server
    try {
      final uri = Uri.parse('/version.json?t=$timestamp');
      final res = await _httpClient.get(uri, headers: const {'Accept': 'application/json'});
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) {
          final serverVersion = decoded['version']?.toString() ?? '';
          final serverBuild = int.tryParse(decoded['build_number']?.toString() ?? '') ?? 0;

          // Jika ini pertama kali dibuka dan PackageInfo tadi kosong/0, gunakan versi server saat ini
          // sebagai baseline versi yang sedang aktif (bukan dianggap ada update baru)
          if (_runningWebBuildNumber == null || _runningWebBuildNumber == 0) {
            _runningWebBuildNumber = serverBuild > 0 ? serverBuild : currentBuild;
            _runningWebVersion = serverVersion.isNotEmpty ? serverVersion : currentVersion;
            return AppUpdateCheckResult(
              status: AppUpdateStatus.upToDate,
              currentVersion: _runningWebVersion ?? currentVersion,
              currentBuildNumber: _runningWebBuildNumber ?? currentBuild,
            );
          }

          final baselineBuild = _runningWebBuildNumber!;
          final baselineVersion = _runningWebVersion ?? currentVersion;

          final isHigherBuild = serverBuild > baselineBuild;
          final isHigherVersion = _isVersionHigher(serverVersion, baselineVersion);

          if (isHigherBuild || (serverBuild == baselineBuild && isHigherVersion)) {
            return AppUpdateCheckResult(
              status: AppUpdateStatus.updateAvailable,
              currentVersion: baselineVersion,
              currentBuildNumber: baselineBuild,
              manifest: AppUpdateManifest(
                version: serverVersion.isNotEmpty ? serverVersion : baselineVersion,
                buildNumber: serverBuild > 0 ? serverBuild : baselineBuild,
                mandatory: false,
                url: '',
              ),
            );
          }
        }
      }
    } catch (_) {}

    return AppUpdateCheckResult(
      status: AppUpdateStatus.upToDate,
      currentVersion: _runningWebVersion ?? currentVersion,
      currentBuildNumber: _runningWebBuildNumber ?? currentBuild,
    );
  }

  /// Memeriksa apakah format versi semantik baru (X.Y.Z) lebih tinggi dari versi lama
  static bool _isVersionHigher(String newVer, String oldVer) {
    if (newVer.isEmpty || oldVer.isEmpty || newVer == oldVer) return false;
    try {
      final newParts = newVer.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final oldParts = oldVer.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      for (int i = 0; i < 3; i++) {
        final n = i < newParts.length ? newParts[i] : 0;
        final o = i < oldParts.length ? oldParts[i] : 0;
        if (n > o) return true;
        if (n < o) return false;
      }
    } catch (_) {}
    return false;
  }
}


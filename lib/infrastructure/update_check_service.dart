import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sync/bounded_http_client.dart';

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUri,
  });

  final String currentVersion;
  final String latestVersion;
  final Uri releaseUri;

  bool get isLatest =>
      compareReleaseVersions(currentVersion, latestVersion) == 0;

  bool get updateAvailable =>
      compareReleaseVersions(latestVersion, currentVersion) > 0;

  bool get isDevelopmentVersion =>
      compareReleaseVersions(currentVersion, latestVersion) > 0;
}

class UpdateCheckService {
  UpdateCheckService({
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 15),
  })  : _client = BoundedHttpClient(
          client ?? http.Client(),
          limitFor: (_) => maxResponseBytes,
        ),
        _ownsClient = client == null;

  /// This fork publishes Android test builds as prereleases. The release list
  /// includes them, whereas GitHub's /latest endpoint can return 404.
  static final latestReleaseApi = Uri.parse(
    'https://api.github.com/repos/pandablin/Netcatty-mobile/releases?per_page=30',
  );
  static final latestReleasePage = Uri.parse(
    'https://github.com/pandablin/Netcatty-mobile/releases',
  );
  static const maxResponseBytes = 2 * 1024 * 1024;
  static final _releaseTag = RegExp(
    r'^[vV]?[0-9]+(?:\.[0-9]+){0,2}'
    r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );

  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;

  Future<UpdateCheckResult> check(String currentVersion) async {
    late final http.Response response;
    try {
      response = await _client.get(
        latestReleaseApi,
        headers: const {
          'accept': 'application/vnd.github+json',
          'x-github-api-version': '2022-11-28',
          'user-agent': 'Netcatty-Mobile',
        },
      ).timeout(requestTimeout);
    } on TimeoutException {
      throw const UpdateCheckException('检查更新超时，请稍后重试');
    } on http.ClientException {
      throw const UpdateCheckException('无法连接 GitHub，请检查网络后重试');
    } on StateError catch (error) {
      throw UpdateCheckException(error.message);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UpdateCheckException(
        '检查更新失败（HTTP ${response.statusCode}）',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const UpdateCheckException('GitHub 返回了无法识别的版本信息');
    }
    if (decoded is! List) {
      throw const UpdateCheckException('GitHub 返回了无法识别的版本信息');
    }
    UpdateCheckResult? latest;
    for (final release in decoded) {
      if (release is! Map || release['draft'] == true) continue;
      final rawTag = release['tag_name'];
      if (rawTag is! String) continue;
      final tagName = rawTag.trim();
      if (!_releaseTag.hasMatch(tagName)) continue;
      final version = tagName.replaceFirst(RegExp(r'^[vV]'), '');
      try {
        // Ignore malformed tags instead of allowing one to hide valid builds.
        compareReleaseVersions(version, version);
        if (latest == null ||
            compareReleaseVersions(version, latest.latestVersion) > 0) {
          latest = UpdateCheckResult(
            currentVersion: currentVersion,
            latestVersion: version,
            releaseUri: _releasePage(release['html_url'], tagName),
          );
        }
      } on FormatException {
        continue;
      }
    }
    if (latest == null) {
      throw const UpdateCheckException('GitHub 仓库中没有可用的 Release');
    }
    try {
      compareReleaseVersions(currentVersion, latest.latestVersion);
    } on FormatException {
      throw const UpdateCheckException('最新 Release 版本号格式无效');
    }
    return latest;
  }

  Uri _releasePage(Object? value, String tagName) {
    final candidate = value is String ? Uri.tryParse(value) : null;
    final expectedPath = 'pandablin/Netcatty-mobile/releases/tag/$tagName';
    return candidate != null &&
            candidate.scheme == 'https' &&
            candidate.host == 'github.com' &&
            candidate.port == 443 &&
            candidate.userInfo.isEmpty &&
            !candidate.hasQuery &&
            !candidate.hasFragment &&
            candidate.pathSegments.join('/') == expectedPath
        ? candidate
        : latestReleasePage;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

int compareReleaseVersions(String left, String right) {
  final leftVersion = _ReleaseVersion.parse(left);
  final rightVersion = _ReleaseVersion.parse(right);
  for (var index = 0; index < 3; index++) {
    final compared = leftVersion.numbers[index].compareTo(
      rightVersion.numbers[index],
    );
    if (compared != 0) return compared;
  }

  final leftPre = leftVersion.preRelease;
  final rightPre = rightVersion.preRelease;
  if (leftPre == null && rightPre == null) return 0;
  if (leftPre == null) return 1;
  if (rightPre == null) return -1;
  final length =
      leftPre.length > rightPre.length ? leftPre.length : rightPre.length;
  for (var index = 0; index < length; index++) {
    if (index >= leftPre.length) return -1;
    if (index >= rightPre.length) return 1;
    final leftPart = leftPre[index];
    final rightPart = rightPre[index];
    final leftNumber = int.tryParse(leftPart);
    final rightNumber = int.tryParse(rightPart);
    if (leftNumber != null && rightNumber != null) {
      final compared = leftNumber.compareTo(rightNumber);
      if (compared != 0) return compared;
    } else if (leftNumber != null) {
      return -1;
    } else if (rightNumber != null) {
      return 1;
    } else {
      final compared = leftPart.compareTo(rightPart);
      if (compared != 0) return compared;
    }
  }
  return 0;
}

class _ReleaseVersion {
  const _ReleaseVersion(this.numbers, this.preRelease);

  final List<int> numbers;
  final List<String>? preRelease;

  factory _ReleaseVersion.parse(String value) {
    final withoutPrefix = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final withoutBuild = withoutPrefix.split('+').first;
    final dash = withoutBuild.indexOf('-');
    final core = dash < 0 ? withoutBuild : withoutBuild.substring(0, dash);
    final rawPre = dash < 0 ? null : withoutBuild.substring(dash + 1);
    final parts = core.split('.');
    if (parts.isEmpty || parts.length > 3) {
      throw FormatException('Invalid release version: $value');
    }
    final numbers = <int>[];
    for (final part in parts) {
      final parsed = int.tryParse(part);
      if (parsed == null || parsed < 0) {
        throw FormatException('Invalid release version: $value');
      }
      numbers.add(parsed);
    }
    while (numbers.length < 3) {
      numbers.add(0);
    }
    final preRelease = rawPre
        ?.split('.')
        .where((part) => part.isNotEmpty)
        .map((part) => part.toLowerCase())
        .toList(growable: false);
    if (preRelease?.isEmpty ?? false) {
      throw FormatException('Invalid release version: $value');
    }
    return _ReleaseVersion(numbers, preRelease);
  }
}

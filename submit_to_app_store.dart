#!/usr/bin/env dart
/// =============================================================================
/// Flutter Automatic Deploy - App Store Connect API Automation
/// =============================================================================
///
/// Built by Filip Kowalski
/// X: @filippkowalski
/// Website: fkowalski.com
/// Support: https://buymeacoffee.com/filipkowalski
///
/// Automates release notes and review submission after IPA upload.
///
/// =============================================================================
///
/// Usage:
///     dart submit_to_app_store.dart <version> [--project-path PATH] [--dry-run]
///
/// Example:
///     dart submit_to_app_store.dart 1.13.0
///     dart submit_to_app_store.dart 1.13.0 --project-path /path/to/project
///     dart submit_to_app_store.dart 1.13.0 --dry-run
///
/// Environment Variables (required):
///     APP_STORE_API_KEY_ID     - App Store Connect API Key ID
///     APP_STORE_ISSUER_ID      - App Store Connect Issuer ID
///     APP_STORE_P8_KEY_PATH    - Path to .p8 private key file (default: ~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8)
///
/// Dependencies:
///     Add to pubspec.yaml:
///     dependencies:
///       args: ^2.4.0
///       http: ^1.1.0
///       jose: ^0.3.4

import 'dart:io';
import 'dart:convert';
import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';

// API Configuration from environment variables
final apiKeyId = Platform.environment['APP_STORE_API_KEY_ID'];
final issuerId = Platform.environment['APP_STORE_ISSUER_ID'];
final p8KeyPath = Platform.environment['APP_STORE_P8_KEY_PATH'] ??
    (apiKeyId != null
        ? '${Platform.environment['HOME']}/.appstoreconnect/private_keys/AuthKey_$apiKeyId.p8'
        : null);
const baseUrl = 'https://api.appstoreconnect.apple.com/v1';
const releaseNotes = 'Bug fixes and improvements.';

// Colors for output
class Colors {
  static const blue = '\x1B[0;34m';
  static const green = '\x1B[0;32m';
  static const yellow = '\x1B[1;33m';
  static const red = '\x1B[0;31m';
  static const cyan = '\x1B[0;36m';
  static const reset = '\x1B[0m';
}

void log(String emoji, String message, [String color = Colors.reset]) {
  print('$color$emoji $message${Colors.reset}');
}

void checkEnvironmentVariables() {
  final missing = <String>[];

  if (apiKeyId == null) missing.add('APP_STORE_API_KEY_ID');
  if (issuerId == null) missing.add('APP_STORE_ISSUER_ID');

  if (missing.isNotEmpty) {
    log('❌', 'Missing required environment variables:', Colors.red);
    for (final variable in missing) {
      log('', '  - $variable', Colors.red);
    }
    print('');
    log('💡', 'Set them with:', Colors.yellow);
    log('', '  export APP_STORE_API_KEY_ID=your_key_id', Colors.cyan);
    log('', '  export APP_STORE_ISSUER_ID=your_issuer_id', Colors.cyan);
    log('', '  export APP_STORE_P8_KEY_PATH=/path/to/AuthKey.p8  # optional',
        Colors.cyan);
    print('');
    log('💡',
        'You can find these in App Store Connect > Users and Access > Keys',
        Colors.yellow);
    exit(1);
  }
}

String? findBundleId(String projectPath) {
  log('🔍', 'Detecting bundle ID from Xcode project...', Colors.cyan);

  // Look for project.pbxproj file
  var iosPath = Directory('$projectPath/ios');

  if (!iosPath.existsSync()) {
    // Try mobile/ios for nested Flutter projects
    iosPath = Directory('${Directory(projectPath).parent.path}/ios');
  }

  final pbxprojFiles = iosPath
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('project.pbxproj'))
      .toList();

  if (pbxprojFiles.isEmpty) {
    log('❌', 'Could not find project.pbxproj file', Colors.red);
    return null;
  }

  final pbxprojPath = pbxprojFiles.first;

  // Parse bundle ID from project file
  final content = pbxprojPath.readAsStringSync();

  // Look for PRODUCT_BUNDLE_IDENTIFIER
  final match =
      RegExp(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);').firstMatch(content);

  if (match != null) {
    var bundleId = match.group(1)!.trim().replaceAll('"', '');

    // Handle $(PRODUCT_BUNDLE_IDENTIFIER) references
    if (bundleId.startsWith(r'$(')) {
      // Look for the actual value
      final actualMatch = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([a-z0-9\.]+)"?;')
          .firstMatch(content);
      if (actualMatch != null) {
        bundleId = actualMatch.group(1)!;
      }
    }

    log('✅', 'Found bundle ID: $bundleId', Colors.green);
    return bundleId;
  }

  log('❌', 'Could not parse bundle ID from project file', Colors.red);
  return null;
}

Future<String> generateJwtToken() async {
  if (p8KeyPath == null || !File(p8KeyPath!).existsSync()) {
    log('❌', 'P8 key file not found: $p8KeyPath', Colors.red);
    log('💡',
        'Set APP_STORE_P8_KEY_PATH or place the key at the default location',
        Colors.yellow);
    exit(1);
  }

  try {
    final p8Content = await File(p8KeyPath!).readAsString();

    // Create JWT claims
    final claims = JsonWebTokenClaims.fromJson({
      'iss': issuerId,
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'exp': DateTime.now().add(Duration(minutes: 19)).millisecondsSinceEpoch ~/
          1000,
      'aud': 'appstoreconnect-v1',
    });

    // Create JWT builder
    final builder = JsonWebSignatureBuilder()
      ..jsonContent = claims.toJson()
      ..addRecipient(
        JsonWebKey.fromPem(p8Content, keyId: apiKeyId),
        algorithm: 'ES256',
      );

    // Build and serialize the token
    final jws = builder.build();
    return jws.toCompactSerialization();
  } catch (e) {
    log('❌', 'Failed to generate JWT token: $e', Colors.red);
    exit(1);
  }
}

Future<Map<String, dynamic>?> makeApiRequest(
  String method,
  String endpoint, {
  Map<String, dynamic>? data,
  int retries = 3,
}) async {
  final token = await generateJwtToken();
  final headers = {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  final url = Uri.parse('$baseUrl$endpoint');

  for (var attempt = 0; attempt < retries; attempt++) {
    try {
      http.Response response;

      switch (method) {
        case 'GET':
          response = await http.get(url, headers: headers).timeout(
                Duration(seconds: 30),
              );
          break;
        case 'POST':
          response = await http
              .post(url, headers: headers, body: jsonEncode(data))
              .timeout(Duration(seconds: 30));
          break;
        case 'PATCH':
          response = await http
              .patch(url, headers: headers, body: jsonEncode(data))
              .timeout(Duration(seconds: 30));
          break;
        default:
          throw Exception('Unsupported HTTP method: $method');
      }

      // Handle rate limiting
      if (response.statusCode == 429) {
        final waitTime = int.tryParse(response.headers['retry-after'] ?? '60') ?? 60;
        log('⏳', 'Rate limited. Waiting ${waitTime}s...', Colors.yellow);
        await Future.delayed(Duration(seconds: waitTime));
        continue;
      }

      // Handle errors
      if (response.statusCode >= 400) {
        final errorData =
            response.body.isNotEmpty ? jsonDecode(response.body) : {};
        final errorMsg = errorData['errors']?[0]?['detail'] ?? 'Unknown error';

        log('❌', 'API Error (${response.statusCode}): $errorMsg', Colors.red);

        if (attempt < retries - 1) {
          log('🔄', 'Retrying... (attempt ${attempt + 2}/$retries)',
              Colors.yellow);
          await Future.delayed(Duration(seconds: 5 * (attempt + 1)));
          continue;
        }

        return null;
      }

      return jsonDecode(response.body);
    } on TimeoutException {
      log('⏳', 'Request timed out', Colors.yellow);
      if (attempt < retries - 1) {
        await Future.delayed(Duration(seconds: 5 * (attempt + 1)));
        continue;
      }
      return null;
    } catch (e) {
      log('❌', 'Network error: $e', Colors.red);
      if (attempt < retries - 1) {
        await Future.delayed(Duration(seconds: 5 * (attempt + 1)));
        continue;
      }
      return null;
    }
  }

  return null;
}

Future<String?> findAppByBundleId(String bundleId) async {
  log('🔍', 'Finding app with bundle ID: $bundleId', Colors.cyan);

  final response =
      await makeApiRequest('GET', '/apps?filter[bundleId]=$bundleId');

  if (response == null || response['data'] == null || response['data'].isEmpty) {
    log('❌', 'App not found with bundle ID: $bundleId', Colors.red);
    log('💡', 'Make sure the app exists in App Store Connect', Colors.yellow);
    return null;
  }

  final appId = response['data'][0]['id'] as String;
  final appName = response['data'][0]['attributes']['name'] as String;
  log('✅', 'Found app: $appName (ID: ${appId.substring(0, 12)}...)',
      Colors.green);
  return appId;
}

Future<String?> waitForBuildProcessing(
  String appId, {
  String? expectedBuildNumber,
  int maxWaitMinutes = 60,
  bool dryRun = false,
}) async {
  if (expectedBuildNumber != null) {
    log(
        '⏳',
        'Waiting for build $expectedBuildNumber to finish processing (max $maxWaitMinutes min)...',
        Colors.cyan);
  } else {
    log('⏳',
        'Waiting for latest build to finish processing (max $maxWaitMinutes min)...',
        Colors.cyan);
  }

  if (dryRun) {
    log('🧪', '[DRY RUN] Skipping build processing wait', Colors.yellow);
    return 'dry-run-build-id';
  }

  final startTime = DateTime.now();
  final maxWaitDuration = Duration(minutes: maxWaitMinutes);
  String? lastState;
  String? lastVersion;

  while (true) {
    // Get recent builds (limit 5 to catch the new build faster)
    final response = await makeApiRequest('GET',
        '/builds?filter[app]=$appId&sort=-uploadedDate&limit=5');

    if (response == null || response['data'] == null || response['data'].isEmpty) {
      log('❌', 'No builds found', Colors.red);
      log('💡', 'Make sure you uploaded the IPA with xcrun altool first',
          Colors.yellow);
      return null;
    }

    // Look for the specific build or use the latest
    Map<String, dynamic>? targetBuild;

    if (expectedBuildNumber != null) {
      // Search for the specific build number
      for (final build in response['data']) {
        final buildVersion = build['attributes']['version'] as String?;
        if (buildVersion == expectedBuildNumber) {
          targetBuild = build;
          break;
        }
      }

      if (targetBuild == null) {
        // Build not found yet, keep waiting
        final elapsed = DateTime.now().difference(startTime);
        if (elapsed > maxWaitDuration) {
          log('⏱️', 'Timeout after $maxWaitMinutes minutes', Colors.yellow);
          log('❌',
              'Build $expectedBuildNumber never appeared in App Store Connect',
              Colors.yellow);
          log('💡', 'Check App Store Connect to verify the upload succeeded',
              Colors.yellow);
          return null;
        }

        // Show waiting message every 30 seconds
        if (elapsed.inSeconds % 30 == 0 && elapsed.inSeconds > 0) {
          log(
              '⏳',
              'Still waiting for build $expectedBuildNumber to appear... (${elapsed.inSeconds}s elapsed)',
              Colors.blue);
        }

        await Future.delayed(Duration(seconds: 5));
        continue;
      }
    } else {
      // No specific build number, use the latest
      targetBuild = response['data'][0];
    }

    final buildId = targetBuild['id'] as String;
    final processingState =
        targetBuild['attributes']['processingState'] as String? ?? 'UNKNOWN';
    final version =
        targetBuild['attributes']['version'] as String? ?? 'unknown';

    // Show progress only if state changed
    if (processingState != lastState || version != lastVersion) {
      log('📦', 'Build $version - State: $processingState', Colors.blue);
      lastState = processingState;
      lastVersion = version;
    }

    if (processingState == 'VALID') {
      log('✅', 'Build $version is ready!', Colors.green);
      return buildId;
    } else if (processingState == 'INVALID') {
      log('❌', 'Build $version processing failed', Colors.red);
      log('💡', 'Check App Store Connect for details', Colors.yellow);
      return null;
    }

    // Check timeout
    final elapsed = DateTime.now().difference(startTime);
    if (elapsed > maxWaitDuration) {
      log('⏱️', 'Timeout after $maxWaitMinutes minutes', Colors.yellow);
      log('⏳',
          'Build $version is still processing. Run this script again later:',
          Colors.yellow);
      log('', '  dart submit_to_app_store.dart $version', Colors.cyan);
      return null;
    }

    // Wait before next check (30 seconds for specific build, 5s when searching)
    await Future.delayed(
        Duration(seconds: targetBuild != null && processingState != 'PROCESSING' ? 30 : 5));
  }
}

Future<String?> getOrCreateVersion(
  String appId,
  String versionString, {
  bool dryRun = false,
}) async {
  log('🔍', 'Looking for version $versionString...', Colors.cyan);

  // Check if version exists
  final response = await makeApiRequest('GET',
      '/apps/$appId/appStoreVersions?filter[platform]=IOS&filter[versionString]=$versionString');

  if (response == null) return null;

  if (response['data'] != null && response['data'].isNotEmpty) {
    final versionId = response['data'][0]['id'] as String;
    final state =
        response['data'][0]['attributes']['appStoreState'] as String? ??
            'UNKNOWN';
    log('✅', 'Found existing version: $versionString (State: $state)',
        Colors.green);

    // Check if already submitted
    if ([
      'WAITING_FOR_REVIEW',
      'IN_REVIEW',
      'PENDING_DEVELOPER_RELEASE',
      'READY_FOR_SALE'
    ].contains(state)) {
      log('⚠️', 'Version already in state: $state', Colors.yellow);
      log('⏭️', 'Skipping submission (already submitted)', Colors.yellow);
      return null;
    }

    return versionId;
  }

  // Create new version
  if (dryRun) {
    log('🧪', '[DRY RUN] Would create new version $versionString',
        Colors.yellow);
    return 'dry-run-version-id';
  }

  log('✨', 'Creating new version $versionString...', Colors.cyan);
  final data = {
    'data': {
      'type': 'appStoreVersions',
      'attributes': {'platform': 'IOS', 'versionString': versionString},
      'relationships': {
        'app': {
          'data': {'type': 'apps', 'id': appId}
        }
      }
    }
  };

  final createResponse = await makeApiRequest('POST', '/appStoreVersions', data: data);

  if (createResponse == null) return null;

  final versionId = createResponse['data']['id'] as String;
  log('✅', 'Created version: $versionString', Colors.green);
  return versionId;
}

Future<bool> linkBuildToVersion(
  String versionId,
  String buildId, {
  bool dryRun = false,
}) async {
  if (dryRun) {
    log('🧪', '[DRY RUN] Would link build to version', Colors.yellow);
    return true;
  }

  log('🔗', 'Linking build to version...', Colors.cyan);

  final data = {
    'data': {
      'type': 'appStoreVersions',
      'id': versionId,
      'relationships': {
        'build': {
          'data': {'type': 'builds', 'id': buildId}
        }
      }
    }
  };

  final response =
      await makeApiRequest('PATCH', '/appStoreVersions/$versionId', data: data);

  if (response == null) return false;

  log('✅', 'Build linked to version', Colors.green);
  return true;
}

Future<bool> addReleaseNotesAllLocales(
  String versionId,
  String releaseNotes, {
  bool dryRun = false,
}) async {
  if (dryRun) {
    log('🧪', '[DRY RUN] Would add release notes to all locales: "$releaseNotes"',
        Colors.yellow);
    return true;
  }

  log('📝', 'Adding release notes for all localizations...', Colors.cyan);

  // Get all existing localizations
  final response = await makeApiRequest('GET',
      '/appStoreVersions/$versionId/appStoreVersionLocalizations');

  if (response == null) return false;

  final localizations = response['data'] as List? ?? [];

  if (localizations.isEmpty) {
    log('⚠️', 'No localizations found', Colors.yellow);
    return false;
  }

  var successCount = 0;
  final totalCount = localizations.length;

  for (final loc in localizations) {
    final localeCode = loc['attributes']['locale'] as String;
    final locId = loc['id'] as String;

    // Update existing localization with release notes
    final data = {
      'data': {
        'type': 'appStoreVersionLocalizations',
        'id': locId,
        'attributes': {'whatsNew': releaseNotes}
      }
    };

    final updateResponse = await makeApiRequest(
        'PATCH', '/appStoreVersionLocalizations/$locId',
        data: data);

    if (updateResponse != null) {
      log('✅', 'Added release notes for $localeCode', Colors.green);
      successCount++;
    } else {
      log('⚠️', 'Failed to add release notes for $localeCode', Colors.yellow);
    }
  }

  if (successCount == totalCount) {
    log('✅', 'Release notes added to all $totalCount localizations',
        Colors.green);
    return true;
  } else if (successCount > 0) {
    log('⚠️', 'Release notes added to $successCount/$totalCount localizations',
        Colors.yellow);
    return true;
  } else {
    log('❌', 'Failed to add release notes to any localization', Colors.red);
    return false;
  }
}

Future<bool> submitForReview(
  String versionId,
  String appId, {
  bool dryRun = false,
}) async {
  if (dryRun) {
    log('🧪', '[DRY RUN] Would submit for review', Colors.yellow);
    return true;
  }

  log('🚀', 'Submitting for review...', Colors.cyan);

  // Step 1: Create a review submission
  log('   ', 'Creating review submission...', Colors.cyan);
  final createData = {
    'data': {
      'type': 'reviewSubmissions',
      'relationships': {
        'app': {
          'data': {'type': 'apps', 'id': appId}
        }
      }
    }
  };

  final response = await makeApiRequest('POST', '/reviewSubmissions', data: createData);
  if (response == null) {
    // Try the legacy endpoint as fallback
    log('   ', 'Trying legacy submission endpoint...', Colors.yellow);
    return await submitForReviewLegacy(versionId);
  }

  final submissionId = response['data']['id'] as String;
  log('   ', 'Created review submission: $submissionId', Colors.green);

  // Step 2: Add the version to the submission
  log('   ', 'Adding version to submission...', Colors.cyan);
  final itemData = {
    'data': {
      'type': 'reviewSubmissionItems',
      'relationships': {
        'reviewSubmission': {
          'data': {'type': 'reviewSubmissions', 'id': submissionId}
        },
        'appStoreVersion': {
          'data': {'type': 'appStoreVersions', 'id': versionId}
        }
      }
    }
  };

  final itemResponse =
      await makeApiRequest('POST', '/reviewSubmissionItems', data: itemData);
  if (itemResponse == null) {
    log('⚠️', 'Failed to add version to submission', Colors.yellow);
    log('💡', 'Please submit manually via App Store Connect', Colors.yellow);
    return false;
  }

  // Step 3: Confirm/submit the review submission
  log('   ', 'Confirming submission...', Colors.cyan);
  final confirmData = {
    'data': {
      'type': 'reviewSubmissions',
      'id': submissionId,
      'attributes': {'submitted': true}
    }
  };

  final confirmResponse = await makeApiRequest('PATCH',
      '/reviewSubmissions/$submissionId',
      data: confirmData);
  if (confirmResponse == null) {
    log('⚠️', 'Failed to confirm submission', Colors.yellow);
    log('💡', 'Please submit manually via App Store Connect', Colors.yellow);
    return false;
  }

  log('✅', 'Submitted for review!', Colors.green);
  return true;
}

Future<bool> submitForReviewLegacy(String versionId) async {
  final data = {
    'data': {
      'type': 'appStoreVersionSubmissions',
      'relationships': {
        'appStoreVersion': {
          'data': {'type': 'appStoreVersions', 'id': versionId}
        }
      }
    }
  };

  final response =
      await makeApiRequest('POST', '/appStoreVersionSubmissions', data: data);

  if (response == null) {
    log('⚠️', 'Submission failed - may require manual action', Colors.yellow);
    log('💡', 'Please check App Store Connect and submit manually',
        Colors.yellow);
    return false;
  }

  log('✅', 'Submitted for review!', Colors.green);
  return true;
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('project-path',
        defaultsTo: Directory.current.path,
        help: 'Path to Flutter project')
    ..addFlag('dry-run',
        negatable: false,
        help: 'Preview without making changes')
    ..addOption('bundle-id', help: 'Override bundle ID detection')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');

  try {
    final results = parser.parse(arguments);

    if (results['help'] as bool || results.rest.isEmpty) {
      print('App Store Connect Automation');
      print('Built by Filip Kowalski | @filippkowalski | fkowalski.com\n');
      print('Usage: dart submit_to_app_store.dart <version> [options]\n');
      print('Example:');
      print('  dart submit_to_app_store.dart 1.13.0');
      print('  dart submit_to_app_store.dart 1.13.0 --dry-run\n');
      print(parser.usage);
      exit(0);
    }

    final version = results.rest[0];
    final projectPath = results['project-path'] as String;
    final dryRun = results['dry-run'] as bool;
    final bundleIdOverride = results['bundle-id'] as String?;

    print('${Colors.cyan}${'=' * 60}${Colors.reset}');
    print('${Colors.cyan}App Store Connect Automation${Colors.reset}');
    print(
        '${Colors.cyan}Built by Filip Kowalski | @filippkowalski | fkowalski.com${Colors.reset}');
    print('${Colors.cyan}${'=' * 60}${Colors.reset}');

    // Check environment variables first
    checkEnvironmentVariables();

    if (dryRun) {
      log('🧪', 'DRY RUN MODE - No changes will be made', Colors.yellow);
      print('');
    }

    // Parse version string to extract version and build number
    // Format: 1.13.0+30 or just 1.13.0
    String versionPart;
    String? buildNumber;

    if (version.contains('+')) {
      final parts = version.split('+');
      versionPart = parts[0];
      buildNumber = parts[1];
      log('📋', 'Parsed: Version $versionPart, Build $buildNumber', Colors.blue);
    } else {
      versionPart = version;
      log('📋', 'Version $versionPart (no specific build number)', Colors.blue);
    }

    print('');

    // 1. Detect or use provided bundle ID
    final bundleId = bundleIdOverride ?? findBundleId(projectPath);
    if (bundleId == null) {
      log('❌',
          'Could not detect bundle ID. Use --bundle-id to specify manually',
          Colors.red);
      exit(1);
    }

    print('');

    // 2. Find app
    final appId = await findAppByBundleId(bundleId);
    if (appId == null) exit(1);

    print('');

    // 3. Wait for build to be ready (with specific build number if provided)
    final buildId = await waitForBuildProcessing(
      appId,
      expectedBuildNumber: buildNumber,
      dryRun: dryRun,
    );
    if (buildId == null) exit(1);

    print('');

    // 4. Get or create version (use version part only, without build number)
    final versionId =
        await getOrCreateVersion(appId, versionPart, dryRun: dryRun);
    if (versionId == null) {
      if (!dryRun) {
        log('⚠️', 'Version may already be submitted', Colors.yellow);
      }
      exit(0); // Not an error, just already done
    }

    print('');

    // 5. Link build to version
    if (!await linkBuildToVersion(versionId, buildId, dryRun: dryRun)) {
      exit(1);
    }

    print('');

    // 6. Add release notes to ALL localizations
    if (!await addReleaseNotesAllLocales(versionId, releaseNotes,
        dryRun: dryRun)) {
      exit(1);
    }

    print('');

    // 7. Submit for review
    final submissionSuccess =
        await submitForReview(versionId, appId, dryRun: dryRun);

    print('');
    print('${Colors.cyan}${'=' * 60}${Colors.reset}');
    if (dryRun) {
      log('🧪', 'DRY RUN COMPLETE - No changes were made', Colors.yellow);
    } else if (submissionSuccess) {
      log('✅', 'Success! App submitted for review', Colors.green);
    } else {
      log('⚠️', 'Setup complete, but submission requires manual action',
          Colors.yellow);
      log('💡',
          'Version created and configured - please submit via App Store Connect',
          Colors.yellow);
    }
    print('${Colors.cyan}${'=' * 60}${Colors.reset}');
    print('');
    log('📋',
        'Version: $versionPart${buildNumber != null ? ' (Build $buildNumber)' : ''}',
        Colors.blue);
    log('📝', 'Release notes: $releaseNotes', Colors.blue);
    log('🌐', 'View status: https://appstoreconnect.apple.com', Colors.blue);
  } on FormatException catch (e) {
    print('Error: ${e.message}\n');
    print(parser.usage);
    exit(1);
  } catch (e) {
    print('');
    log('❌', 'Unexpected error: $e', Colors.red);
    exit(1);
  }
}

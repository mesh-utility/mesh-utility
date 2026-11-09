import 'dart:convert';

import 'package:http/http.dart' as http;

/// GitHub latest-release endpoint. The API allows browser CORS.
const String latestGithubReleaseApi =
    'https://api.github.com/repos/mesh-utility/mesh-utility/releases/latest';

/// Bundled notes used when the GitHub request fails.
const String bundledReleaseNotesAsset = 'docs/releases/latest.md';

class GithubReleaseNotes {
  const GithubReleaseNotes({
    required this.tagName,
    required this.body,
    required this.htmlUrl,
  });

  final String tagName;
  final String body;
  final String htmlUrl;
}

class ReleaseNoteItem {
  const ReleaseNoteItem(this.text, {this.url});

  /// Visible text with markdown link syntax removed.
  final String text;

  /// First markdown link target, when the bullet has one.
  final String? url;
}

class ParsedReleaseNotes {
  const ParsedReleaseNotes({
    required this.fixes,
    required this.enhancements,
    required this.other,
  });

  final List<ReleaseNoteItem> fixes;
  final List<ReleaseNoteItem> enhancements;
  final List<ReleaseNoteItem> other;

  bool get isEmpty => fixes.isEmpty && enhancements.isEmpty && other.isEmpty;
}

final RegExp _headingLine = RegExp(r'^\s*(#{1,6})\s+(.+?)\s*#*\s*$');
final RegExp _bulletLine = RegExp(r'^\s*[-*+]\s+(.*)$');
final RegExp _markdownLink = RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)');

/// Fetches `tag_name`, `body`, and `html_url` from the latest GitHub release.
///
/// This does not check whether on-device contacts are supported, so the web
/// Install tab can call it. The in-app updater fetch is unchanged.
/// Returns null on any failure.
/// A caller-supplied [client] is not closed and is not wrapped in a timeout.
Future<GithubReleaseNotes?> fetchGithubReleaseNotes({
  http.Client? client,
  Uri? uri,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final httpClient = client ?? http.Client();
  final owned = client == null;
  try {
    final pending = httpClient.get(
      uri ?? Uri.parse(latestGithubReleaseApi),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'mesh-utility',
      },
    );
    final response = owned ? await pending.timeout(timeout) : await pending;
    if (response.statusCode != 200) return null;
    final json = jsonDecode(response.body);
    if (json is! Map) return null;
    final tag = (json['tag_name'] ?? '').toString().trim();
    final body = (json['body'] ?? '').toString();
    final htmlUrl = (json['html_url'] ?? '').toString().trim();
    if (tag.isEmpty && body.trim().isEmpty) return null;
    return GithubReleaseNotes(tagName: tag, body: body, htmlUrl: htmlUrl);
  } catch (_) {
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}

/// Groups release-note bullets under Fixes, Enhancements, and Other changes.
///
/// Headings may be any level. "Other" and "Other changes" are the same bucket.
/// When the body has none of those headings, every bullet is Other changes.
/// Bullets under any other heading are also Other changes once a known
/// heading exists.
ParsedReleaseNotes parseReleaseNotes(String body) {
  final fixes = <ReleaseNoteItem>[];
  final enhancements = <ReleaseNoteItem>[];
  final other = <ReleaseNoteItem>[];
  final unknown = <ReleaseNoteItem>[];
  String? current;
  var sawKnown = false;

  void add(ReleaseNoteItem item) {
    if (item.text.isEmpty) return;
    switch (current) {
      case 'Fixes':
        fixes.add(item);
      case 'Enhancements':
        enhancements.add(item);
      case 'Other changes':
        other.add(item);
      default:
        unknown.add(item);
    }
  }

  for (final rawLine in body.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final heading = _headingLine.firstMatch(line);
    if (heading != null) {
      final bucket = _releaseHeadingBucket(heading.group(2)!);
      if (bucket == null) {
        current = 'unknown';
      } else {
        sawKnown = true;
        current = bucket;
      }
      continue;
    }
    final bullet = _bulletLine.firstMatch(rawLine);
    if (bullet != null) {
      add(_itemFromMarkdown(bullet.group(1)!));
      continue;
    }
    if (current != null && _markdownLink.hasMatch(line)) {
      add(_itemFromMarkdown(line));
    }
  }

  if (!sawKnown) {
    return ParsedReleaseNotes(
      fixes: const [],
      enhancements: const [],
      other: List<ReleaseNoteItem>.unmodifiable(unknown),
    );
  }
  return ParsedReleaseNotes(
    fixes: List<ReleaseNoteItem>.unmodifiable(fixes),
    enhancements: List<ReleaseNoteItem>.unmodifiable(enhancements),
    other: List<ReleaseNoteItem>.unmodifiable(<ReleaseNoteItem>[
      ...other,
      ...unknown,
    ]),
  );
}

/// First `Alpha-N` token in bundled markdown, used when GitHub is unreachable.
String? tagFromReleaseMarkdown(String? body) {
  if (body == null || body.isEmpty) return null;
  final match = RegExp(r'Alpha-\d+', caseSensitive: false).firstMatch(body);
  if (match == null) return null;
  final raw = match.group(0)!;
  return 'Alpha-${raw.substring(raw.indexOf('-') + 1)}';
}

String? _releaseHeadingBucket(String heading) {
  final stripped = heading
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[:.]+$'), '');
  switch (stripped) {
    case 'fix':
    case 'fixes':
      return 'Fixes';
    case 'enhancement':
    case 'enhancements':
      return 'Enhancements';
    case 'other':
    case 'other change':
    case 'other changes':
      return 'Other changes';
    default:
      return null;
  }
}

ReleaseNoteItem _itemFromMarkdown(String raw) {
  String? url;
  final text = raw
      .replaceAllMapped(_markdownLink, (match) {
        url ??= match.group(2);
        return match.group(1) ?? '';
      })
      .replaceAll('`', '')
      .trim();
  return ReleaseNoteItem(text, url: url);
}

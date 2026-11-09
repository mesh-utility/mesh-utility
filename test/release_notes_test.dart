import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/services/release_notes.dart';

void main() {
  test('parseReleaseNotes groups known headings at any level', () {
    final notes = parseReleaseNotes('''
# Fixes
- Countdown starts on send. See the [notes](https://example.com/notes).
### Enhancements
- Travel downloads.
## Other changes
- Template added.
## Unsorted
- Still shown.
''');

    expect(notes.fixes, hasLength(1));
    expect(notes.fixes.single.text, contains('Countdown starts on send'));
    expect(notes.fixes.single.text, contains('See the notes'));
    expect(notes.fixes.single.url, 'https://example.com/notes');
    expect(notes.enhancements.single.text, 'Travel downloads.');
    expect(notes.other.map((item) => item.text), [
      'Template added.',
      'Still shown.',
    ]);
  });

  test('parseReleaseNotes puts a body with no known headings under Other', () {
    final notes = parseReleaseNotes('''
## Coverage map
- Hexes stop growing.
[Add to Obtainium](https://example.com/obtainium)
''');

    expect(notes.fixes, isEmpty);
    expect(notes.enhancements, isEmpty);
    expect(notes.other.map((item) => item.text), [
      'Hexes stop growing.',
      'Add to Obtainium',
    ]);
    expect(notes.other.last.url, 'https://example.com/obtainium');
  });

  test('tagFromReleaseMarkdown reads the first Alpha-N token', () {
    expect(tagFromReleaseMarkdown('# Mesh Utility alpha-22'), 'Alpha-22');
    expect(tagFromReleaseMarkdown('no tag here'), isNull);
  });

  test('fetchGithubReleaseNotes reads the latest release JSON', () async {
    final notes = await fetchGithubReleaseNotes(
      client: _ScriptClient((request) async {
        expect(request.url.path, endsWith('/releases/latest'));
        expect(request.headers['User-Agent'], 'mesh-utility');
        return http.Response(
          jsonEncode(<String, String>{
            'tag_name': 'Alpha-22',
            'body': '## Fixes\n- Clock.',
            'html_url': 'https://example.com/rel',
          }),
          200,
        );
      }),
    );

    expect(notes, isNotNull);
    expect(notes!.tagName, 'Alpha-22');
    expect(notes.htmlUrl, 'https://example.com/rel');
    expect(parseReleaseNotes(notes.body).fixes.single.text, 'Clock.');
  });

  test('fetchGithubReleaseNotes returns null when the request fails', () async {
    final notes = await fetchGithubReleaseNotes(
      client: _ScriptClient((request) async {
        return http.Response('nope', 503);
      }),
    );
    expect(notes, isNull);
  });
}

class _ScriptClient extends http.BaseClient {
  _ScriptClient(this._handle);

  final Future<http.Response> Function(http.BaseRequest request) _handle;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _handle(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart' as crypto;

const int kSpaceDiscoveryPublishedSearchTermLimit = 16;
const int kSpaceDiscoveryQueryTermLimit = 4;

final RegExp _spaceDiscoveryWords = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// Locale-independent, whitespace-stable form used both for routing tokens and
/// final result matching. It preserves Unicode letters and numbers instead of
/// applying an ASCII-only sanitizer.
String normalizeSpaceDiscoverySearchText(String value) => _spaceDiscoveryWords
    .allMatches(value.toLowerCase())
    .map((match) => match.group(0)!)
    .join(' ');

/// Bounded name terms published for a discoverable Space. Prefixes make
/// incremental search responsive without placing plaintext names in the DHT.
List<String> spaceDiscoveryPublishedSearchTerms(String name) {
  final normalized = normalizeSpaceDiscoverySearchText(name);
  if (normalized.isEmpty) return const [];
  final terms = <String>{};
  void add(String value) {
    if (value.characters.length >= 2 &&
        utf8.encode(value).length <= 512 &&
        terms.length < kSpaceDiscoveryPublishedSearchTermLimit) {
      terms.add(value);
    }
  }

  add(normalized);
  final words = normalized.split(' ');
  // Reserve one route per complete word before adding prefixes. A long first
  // word must not consume the cap and make later words undiscoverable.
  for (final word in words) {
    add(word);
  }
  for (var length = 2; length <= 8; length++) {
    for (final word in words) {
      final characters = word.characters;
      if (characters.length >= length) {
        add(characters.take(length).toString());
      }
      if (terms.length >= kSpaceDiscoveryPublishedSearchTermLimit) break;
    }
    if (terms.length >= kSpaceDiscoveryPublishedSearchTermLimit) break;
  }
  return List<String>.unmodifiable(terms);
}

/// Bounded routes consulted for one user query. Multi-word queries include
/// both the phrase and its words; final descriptor matching still applies the
/// whole normalized query, so a word hit cannot become a false result.
List<String> spaceDiscoveryQueryTerms(String query) {
  final normalized = normalizeSpaceDiscoverySearchText(query);
  if (normalized.isEmpty) return const [];
  final terms = <String>{};
  void add(String value) {
    if (value.characters.length >= 2 &&
        terms.length < kSpaceDiscoveryQueryTermLimit) {
      terms.add(value);
    }
  }

  add(normalized);
  for (final word in normalized.split(' ')) {
    add(word);
  }
  return List<String>.unmodifiable(terms);
}

Uint8List spaceDiscoverySearchTokenHash(String normalizedTerm) =>
    Uint8List.fromList(
      crypto.sha256
          .convert(
            utf8.encode(
              'xveil.space-discovery.search-token.v1\u0000$normalizedTerm',
            ),
          )
          .bytes,
    );

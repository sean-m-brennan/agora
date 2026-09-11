// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Pure-Dart tests for the agora.profile app-event (Increment 3): decoding the
// core-verified compact JSON into AgoraPeer fields. These never load the native
// shim, so they run under `flutter test` without a built libagora_shim.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/at_peer.dart';

AtRawEvent _profileEvent(List<int> uuid, String profileJson) => AtRawEvent(
      kind: agoraEventProfile,
      uuid: uuid,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      profileJson: profileJson,
    );

void main() {
  final uuid = List<int>.filled(16, 0x11);

  test('profile event populates typed fields', () {
    final peer = AgoraPeer(uuid: uuid);
    expect(peer.hasProfile, isFalse);
    expect(peer.displayLabel, peer.shortId); // falls back to id

    final consumed = peer.applyEvent(_profileEvent(
      uuid,
      jsonEncode({
        'display_name': 'José 🚀',
        'handle': 'jose_b',
        'bio': 'hi there',
        'avatar_ref': 'https://x/a.png',
        'links': ['https://a.example', 'https://b.example'],
      }),
    ));

    expect(consumed, isTrue);
    expect(peer.hasProfile, isTrue);
    expect(peer.displayName, 'José 🚀');
    expect(peer.handle, 'jose_b');
    expect(peer.bio, 'hi there');
    expect(peer.avatarRef, 'https://x/a.png');
    expect(peer.links, ['https://a.example', 'https://b.example']);
    expect(peer.displayLabel, 'José 🚀');
  });

  test('display label falls back to @handle then id', () {
    final peer = AgoraPeer(uuid: uuid);
    peer.applyEvent(_profileEvent(uuid, jsonEncode({'handle': 'only_handle'})));
    expect(peer.displayLabel, '@only_handle');

    final peer2 = AgoraPeer(uuid: uuid);
    expect(peer2.displayLabel, peer2.shortId);
  });

  test('empty profile clears previously-shared fields', () {
    final peer = AgoraPeer(uuid: uuid);
    peer.applyEvent(_profileEvent(uuid, jsonEncode({'display_name': 'Was Set'})));
    expect(peer.hasProfile, isTrue);

    peer.applyEvent(_profileEvent(uuid, '')); // opted back out
    expect(peer.hasProfile, isFalse);
    expect(peer.displayName, '');
    expect(peer.links, isEmpty);
  });

  test('malformed profile JSON is ignored, not thrown', () {
    final peer = AgoraPeer(uuid: uuid);
    peer.applyEvent(_profileEvent(uuid, jsonEncode({'display_name': 'Keep'})));
    // Not valid JSON: applyEvent must swallow it and leave prior state intact.
    final consumed = peer.applyEvent(_profileEvent(uuid, '{not json'));
    expect(consumed, isTrue);
    expect(peer.displayName, 'Keep');
  });

  test('non-string fields are dropped defensively', () {
    final peer = AgoraPeer(uuid: uuid);
    peer.applyEvent(_profileEvent(
      uuid,
      jsonEncode({'display_name': 42, 'bio': 'ok', 'links': 'not-a-list'}),
    ));
    expect(peer.displayName, ''); // wrong type dropped
    expect(peer.bio, 'ok');
    expect(peer.links, isEmpty); // wrong type dropped
  });
}

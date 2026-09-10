// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Pure-Dart tests for the peer model and event merge. These do NOT load the
// native shim (they never touch AtEvents), so they run under `flutter test`
// without a built libagora_shim.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/ffi/at_peer.dart';

void main() {
  test('peer event populates identity + presence', () {
    final peer = AgoraPeer(uuid: List<int>.filled(16, 0xAB));
    peer.applyEvent(AtRawEvent(
      kind: agoraEventPeer,
      uuid: List<int>.filled(16, 0xAB),
      signingPubkey: List<int>.filled(32, 1),
      rank: 3,
      operatorBound: true,
      operatorAttestedAt: 1000.0,
      operatorPubkey: List<int>.filled(32, 0),
      repScore: 0,
      repRated: false,
    ));

    expect(peer.rank, 3);
    expect(peer.operatorBound, isTrue);
    expect(peer.hasNamedGuardian, isFalse);
    expect(peer.shortId, 'abababababab'); // 12 hex chars
    expect(peer.presenceLabel(1060.0), 'active now');
    expect(peer.presenceLabel(1600.0), 'attended 10m ago');
  });

  test('reputation event sets score', () {
    final peer = AgoraPeer(uuid: List<int>.filled(16, 0));
    expect(peer.reputationLabel, 'unrated');

    peer.applyEvent(AtRawEvent(
      kind: agoraEventReputation,
      uuid: List<int>.filled(16, 0),
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0.75,
      repRated: true,
    ));

    expect(peer.reputationRated, isTrue);
    expect(peer.reputationLabel, '0.75');
  });

  test('unattended when not operator-bound', () {
    final peer = AgoraPeer(uuid: List<int>.filled(16, 0));
    expect(peer.presenceLabel(9999), 'unattended (no guardian)');
  });

  test('named guardian detected from nonzero operator pubkey', () {
    final peer = AgoraPeer(uuid: List<int>.filled(16, 0));
    peer.applyEvent(AtRawEvent(
      kind: agoraEventPeer,
      uuid: List<int>.filled(16, 0),
      signingPubkey: const [],
      rank: 1,
      operatorBound: true,
      operatorAttestedAt: 0,
      operatorPubkey: List<int>.filled(32, 7),
      repScore: 0,
      repRated: false,
    ));
    expect(peer.hasNamedGuardian, isTrue);
    expect(peer.presenceLabel(9999), 'bound · nobody attending');
  });
}

// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Unit tests for the persisted staff identity + polity charter log (Phase 3
// P3.3). The store is best-effort by design: anything it cannot read in full
// means "this node is staff of no polity", which the roster surface reports as
// a state rather than an error. These tests pin that PARTIAL state is refused
// rather than half-loaded — a log with no key beside it would offer a sign
// button that cannot sign.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/ethne_bindings.dart';
import 'package:agora/src/model/staff_identity.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('agora_polity_test');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  File polityFile() => File('${tmp.path}/etc/at/agora.polity.json');

  StaffIdentity identity() => StaffIdentity(
        polityDid: 'did:key:zCafe',
        self: EthneKeypair(
          'did:key:zAda',
          const {'kty': 'OKP', 'd': 'secret'},
          const {'kty': 'OKP', 'x': 'public'},
        ),
        archive: const {'entries': []},
      );

  Future<void> write(Object json) async {
    final f = polityFile();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(json));
  }

  test('a node with no polity file is staff of nothing, and does not throw',
      () async {
    final store = await StaffIdentityStore(polityFile()).load();
    expect(store.identity, isNull);
  });

  test('a complete identity round-trips through the file', () async {
    final a = StaffIdentityStore(polityFile())..identity = identity();
    await a.save();

    final b = await StaffIdentityStore(polityFile()).load();
    expect(b.identity, isNotNull);
    expect(b.identity!.polityDid, 'did:key:zCafe');
    expect(b.identity!.self.did, 'did:key:zAda');
    expect(b.identity!.self.priv['d'], 'secret');
    expect(b.identity!.archive, {'entries': []});
  });

  test('malformed JSON is staff of nothing, not a crash', () async {
    final f = polityFile();
    await f.parent.create(recursive: true);
    await f.writeAsString('{not json at all');

    final store = await StaffIdentityStore(f).load();
    expect(store.identity, isNull);
  });

  group('partial state is refused rather than half-loaded', () {
    test('a log with no key beside it', () async {
      await write({
        'polity_did': 'did:key:zCafe',
        'archive': {'entries': []},
      });
      expect((await StaffIdentityStore(polityFile()).load()).identity, isNull);
    });

    test('a key with no log to read', () async {
      await write({
        'polity_did': 'did:key:zCafe',
        'self': {'did': 'did:key:zAda', 'priv': {}, 'pub': {}},
      });
      expect((await StaffIdentityStore(polityFile()).load()).identity, isNull);
    });

    test('an empty polity names nothing', () async {
      await write({
        'polity_did': '',
        'self': {'did': 'did:key:zAda', 'priv': {}, 'pub': {}},
        'archive': {'entries': []},
      });
      expect((await StaffIdentityStore(polityFile()).load()).identity, isNull);
    });

    test('a key with no did cannot be attributed to anyone', () async {
      await write({
        'polity_did': 'did:key:zCafe',
        'self': {'did': '', 'priv': {}, 'pub': {}},
        'archive': {'entries': []},
      });
      expect((await StaffIdentityStore(polityFile()).load()).identity, isNull);
    });
  });

  test('a log stored as the raw dumpJson string is accepted too', () async {
    // How a cohort script or a hand-made fixture would write it.
    await write({
      'polity_did': 'did:key:zCafe',
      'self': {'did': 'did:key:zAda', 'priv': {}, 'pub': {}},
      'archive': jsonEncode({'entries': [], 'seq': 3}),
    });
    final store = await StaffIdentityStore(polityFile()).load();
    expect(store.identity, isNotNull);
    expect(store.identity!.archive['seq'], 3);
  });

  test('a log string that is not JSON is refused', () async {
    await write({
      'polity_did': 'did:key:zCafe',
      'self': {'did': 'did:key:zAda', 'priv': {}, 'pub': {}},
      'archive': 'not a log',
    });
    expect((await StaffIdentityStore(polityFile()).load()).identity, isNull);
  });

  test('saving with no identity writes nothing and leaves any file alone',
      () async {
    await write({'polity_did': 'did:key:zCafe'});
    final before = await polityFile().readAsString();

    await StaffIdentityStore(polityFile()).save();

    expect(await polityFile().readAsString(), before);
  });

  test('updating the log keeps the polity and the key', () {
    final store = StaffIdentityStore(polityFile())..identity = identity();
    store.updateArchive(const {'entries': [], 'seq': 9});

    expect(store.identity!.archive['seq'], 9);
    expect(store.identity!.polityDid, 'did:key:zCafe');
    expect(store.identity!.self.did, 'did:key:zAda');
  });

  test('updating the log on a node with no identity does nothing', () {
    final store = StaffIdentityStore(polityFile());
    store.updateArchive(const {'entries': []});
    expect(store.identity, isNull);
  });

  group('the polity root key', () {
    test('an identity with no root is complete — it simply cannot publish', () async {
      final a = StaffIdentityStore(polityFile())..identity = identity();
      await a.save();

      final b = await StaffIdentityStore(polityFile()).load();
      expect(b.identity, isNotNull);
      // Absent is the ordinary state of a staff node, not partial state.
      expect(b.identity!.root, isNull);
    });

    test('a root key round-trips and stays apart from the member key', () async {
      final a = StaffIdentityStore(polityFile())
        ..identity = StaffIdentity(
          polityDid: 'did:key:zCafe',
          self: EthneKeypair('did:key:zAda', const {}, const {}),
          archive: const {'entries': []},
          root: EthneKeypair(
              'did:key:zCafe', const {'d': 'rootsecret'}, const {'x': 'rootpub'}),
        );
      await a.save();

      final b = await StaffIdentityStore(polityFile()).load();
      expect(b.identity!.root, isNotNull);
      expect(b.identity!.root!.did, 'did:key:zCafe');
      expect(b.identity!.root!.priv['d'], 'rootsecret');
      // A member's key speaks for a member; the root key speaks for the polity.
      expect(b.identity!.self.did, 'did:key:zAda');
    });

    test('a root that is present but unreadable refuses the whole identity',
        () async {
      await write({
        'polity_did': 'did:key:zCafe',
        'self': {'did': 'did:key:zAda', 'priv': {}, 'pub': {}},
        'archive': {'entries': []},
        // Corrupt, not absent. A node that half-holds the polity's key should
        // say it holds nothing rather than offer a publish that cannot sign.
        'root': {'did': '', 'priv': {}, 'pub': {}},
      });
      expect((await StaffIdentityStore(polityFile()).load()).identity, isNull);
    });

    test('updating the log keeps the root key too', () {
      final store = StaffIdentityStore(polityFile())
        ..identity = StaffIdentity(
          polityDid: 'did:key:zCafe',
          self: EthneKeypair('did:key:zAda', const {}, const {}),
          archive: const {'entries': []},
          root: EthneKeypair('did:key:zCafe', const {}, const {}),
        );
      store.updateArchive(const {'entries': [], 'seq': 2});
      expect(store.identity!.root, isNotNull);
      expect(store.identity!.archive['seq'], 2);
    });
  });
}

// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The address book (SOCIAL_APP_PLAN Phase 4, multi-device per person): records
// with several devices, our own siblings, links, safety numbers and backups,
// all from decoded events alone.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/model/address_book.dart';
import 'package:agora/src/model/device_cert.dart';
import 'package:agora/src/node/peer_stream.dart';

List<int> _u(int n) => [for (var i = 0; i < 15; i++) 0, n];
String _h(int n) => hexOf(_u(n));

AtRawEvent _ev(int fcKind,
        {int kind = agoraEventContact,
        int who = 0,
        int device = 0,
        String ref = '',
        String nickname = '',
        String petname = '',
        bool verified = false,
        int provenance = 1,
        int origin = 0,
        int count = 0,
        String blob = '',
        String safety = '',
        String path = '',
        String passphrase = '',
        String reason = '',
        int added = 0}) =>
    AtRawEvent(
      kind: kind,
      uuid: _u(who),
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      fcKind: fcKind,
      fcRef: ref,
      fcNickname: nickname,
      fcPetname: petname,
      fcVerified: verified,
      fcProvenance: provenance,
      fcOrigin: origin,
      fcCount: count,
      fcBlob: blob,
      fcSafetyNumber: safety,
      fcDeviceUuid: device == 0 ? const [] : _u(device),
      fcReason: reason,
      backupPath: path,
      backupPassphrase: passphrase,
      backupAdded: added,
    );

void main() {
  group('AddressBook', () {
    test('a list replaces the book, devices and all', () {
      final b = AddressBook();
      for (final e in [
        _ev(atFcContact, who: 1, ref: refBookList, petname: 'Ann', verified: true),
        _ev(atFcDeviceLinked, who: 1, device: 2, ref: refBookList, verified: true),
        _ev(atFcDeviceLinked, who: 1, device: 3, ref: refBookList, verified: true),
        _ev(atFcContact, who: 4, ref: refBookList, petname: 'Bob'),
        _ev(atFcContactsDone, ref: refBookList, count: 2),
      ]) {
        b.ingest(e);
      }
      expect(b.loaded, isTrue);
      expect(b.contacts.keys, {_h(1), _h(4)});
      expect(b.contacts[_h(1)]!.devices, [_h(2), _h(3)]);
      expect(b.personOf(_h(3)), _h(1));
      expect(b.devicesOf(_h(2)), [_h(1), _h(2), _h(3)]);
      expect(b.personOf(_h(9)), _h(9), reason: 'a stranger is their own person');

      // Bob was removed on another device: the next list does not hold him,
      // and nothing of him lingers.
      for (final e in [
        _ev(atFcContact, who: 1, ref: refBookList, petname: 'Ann', verified: true),
        _ev(atFcContactsDone, ref: refBookList, count: 1),
      ]) {
        b.ingest(e);
      }
      expect(b.contacts.keys, [_h(1)]);
      expect(b.contacts[_h(1)]!.devices, isEmpty);
      expect(b.personOf(_h(3)), _h(3));
    });

    test('a list in progress does not disturb the book until it is done', () {
      final b = AddressBook();
      b.ingest(_ev(atFcContact, who: 1, petname: 'Ann'));
      b.ingest(_ev(atFcContact, who: 4, ref: refBookList, petname: 'Bob'));
      expect(b.contacts.keys, [_h(1)]);
      b.ingest(_ev(atFcContactsDone, ref: refBookList, count: 1));
      expect(b.contacts.keys, [_h(4)]);
    });

    test('a live DEVICE_LINKED files the device under its record', () {
      final b = AddressBook();
      b.ingest(_ev(atFcContact, who: 1, petname: 'Ann', verified: true));
      b.ingest(_ev(atFcDeviceLinked, who: 1, device: 2, verified: true));
      expect(b.personOf(_h(2)), _h(1));
      b.ingest(_ev(atFcDeviceLinked, who: 1, device: 2, verified: true));
      expect(b.contacts[_h(1)]!.devices, [_h(2)], reason: 'filed once');
    });

    test('a change from a sibling or a backup asks for a fresh list', () {
      final b = AddressBook();
      b.ingest(_ev(atFcContact, who: 1, petname: 'Ann'));
      expect(b.needsRefresh, isFalse, reason: 'a local edit is already exact');
      b.ingest(_ev(atFcContact, who: 2, origin: atFcOriginSibling));
      expect(b.needsRefresh, isTrue);
      b.needsRefresh = false;
      b.ingest(_ev(atFcRemoved, who: 2, origin: atFcOriginBackup));
      expect(b.needsRefresh, isTrue);
      expect(b.contacts.keys, [_h(1)]);
      b.needsRefresh = false;
      b.ingest(AtRawEventBackup.of(atBackupRestored));
      expect(b.needsRefresh, isTrue);
    });

    test('safety number and verification', () {
      final b = AddressBook();
      b.ingest(_ev(atFcContact, who: 1, petname: 'Ann'));
      b.ingest(_ev(atFcSafetyNumber, who: 1, petname: 'Ann', safety: '12345 67890'));
      expect(b.contacts[_h(1)]!.safetyNumber, '12345 67890');
      b.ingest(_ev(atFcVerified, who: 1, petname: 'Ann', verified: true));
      expect(b.contacts[_h(1)]!.verified, isTrue);
      expect(b.contacts[_h(1)]!.safetyNumber, '12345 67890');
      final r = b.ingest(
          _ev(atFcRefused, ref: refVerify, count: atFcReasonMismatch));
      expect(r.consumed, isFalse, reason: 'a hub request may wait on a refusal too');
      expect(b.lastRefusal!.reason, atFcReasonMismatch);
    });

    test('a hub request refusal is not ours', () {
      final b = AddressBook();
      b.ingest(_ev(atFcRefused, ref: 'ask', count: 6));
      expect(b.lastRefusal, isNull);
    });

    test('links: one to add us, one to pair a device', () {
      final b = AddressBook();
      b.ingest(_ev(atFcInvitation, ref: refInvite, blob: 'at+contact:A'));
      b.ingest(_ev(atFcInvitation, ref: refPairInvite, blob: 'at+contact:P'));
      expect(b.invitation, 'at+contact:A');
      expect(b.pairInvitation, 'at+contact:P');
    });

    test('siblings: paired, listed, removed', () {
      final b = AddressBook();
      b.ingest(_ev(atFcSiblingPaired, who: 7, nickname: 'ann-laptop'));
      expect(b.isSibling(_h(7)), isTrue);
      expect(b.lastPaired!.nickname, 'ann-laptop');
      expect(b.needsRefresh, isTrue, reason: 'the full book arrives after pairing');
      b.ingest(_ev(atFcSibling, who: 8, ref: refSiblingList, nickname: 'ann-tablet'));
      b.ingest(_ev(atFcSiblingsDone, ref: refSiblingList, count: 1));
      expect(b.siblings.keys, [_h(8)], reason: 'a list replaces');
      b.ingest(_ev(atFcSiblingRemoved, who: 8));
      expect(b.siblings, isEmpty);
    });

    test('a generated passphrase reaches the app once, on WRITTEN', () {
      final b = AddressBook();
      b.ingest(AtRawEventBackup.of(atBackupWritten,
          path: '/x/agora.atbk', passphrase: 'ABCD EFGH'));
      expect(b.lastBackup!.passphrase, 'ABCD EFGH');
      expect(b.lastBackup!.refused, isFalse);
      b.ingest(AtRawEventBackup.of(atBackupRefused, reason: 'bad_passphrase'));
      expect(b.lastBackup!.refused, isTrue);
      expect(backupRefusalText(b.lastBackup!.reason), 'Wrong passphrase.');
    });
  });

  group('DeviceCertStatus', () {
    const own = '0000000000000000000000000000000a';
    String cert(String uuid) =>
        '{"body":"{\\"v\\":1,\\"typename\\":\\"at-device-cert\\",\\"operator\\":\\"'
        '17cb79fb2b4120f2b1ec65e4198d6e08b28e813feb01e4a400839b85e18080ce\\",'
        '\\"uuid\\":\\"$uuid\\",\\"key\\":\\"00\\",\\"issued_at\\":1}","sig":"00"}';

    test('ours, foreign, unreadable', () {
      final mine = DeviceCertStatus.parse(
          cert('00000000-0000-0000-0000-00000000000a'), own);
      expect(mine.state, DeviceCertState.ours);
      expect(mine.operatorShort, '17cb 79fb 2b41 20f2');
      expect(
          DeviceCertStatus.parse(cert('00000000-0000-0000-0000-00000000000b'), own)
              .state,
          DeviceCertState.foreign);
      expect(DeviceCertStatus.parse('nope', own).state, DeviceCertState.unreadable);
      expect(DeviceCertStatus.parse('{"body":1}', own).state,
          DeviceCertState.unreadable);
    });
  });

  group('PeerService and the address book', () {
    test('book events reach the book and never become peers', () {
      final s = PeerService();
      s.ingestEvents([
        _ev(atFcContact, who: 1, ref: refBookList, petname: 'Ann', verified: true),
        _ev(atFcDeviceLinked, who: 1, device: 2, ref: refBookList, verified: true),
        _ev(atFcContactsDone, ref: refBookList, count: 1),
        _ev(atFcSibling, who: 7, ref: refSiblingList),
        _ev(atFcSiblingsDone, ref: refSiblingList, count: 1),
      ]);
      expect(s.book.contacts.keys, [_h(1)]);
      expect(s.book.siblings.keys, [_h(7)]);
      expect(s.peers, isEmpty);
    });

    test('a hub request ESTABLISHED reaches both the hubs and the book', () {
      final s = PeerService();
      s.ingestEvents([_ev(atFcEstablished, who: 3, ref: 'ask')]);
      expect(s.book.needsRefresh, isTrue);
      expect(s.hubs.outgoing[_h(3)], isNotNull);
    });

    test('the default backup path is under the node root', () {
      final s = PeerService();
      expect(s.defaultBackupPath(DateTime(2026, 10, 1)),
          endsWith('/var/agora/backups/agora-2026-10-01.atbk'));
      expect(DeviceCertStatus.issueCommand('/r'),
          'AUTONOMOUS_TRUST_ROOT="/r" python3 '
          'src/autonomous-trust-first-contact/tools/device_cert.py issue');
    });
  });
}

/// Backup events, built directly.
class AtRawEventBackup {
  static AtRawEvent of(int fcKind,
          {String path = '', String passphrase = '', String reason = ''}) =>
      AtRawEvent(
        kind: agoraEventBackup,
        uuid: const [],
        signingPubkey: const [],
        rank: 0,
        operatorBound: false,
        operatorAttestedAt: 0,
        operatorPubkey: const [],
        repScore: 0,
        repRated: false,
        rttMs: 0,
        fcKind: fcKind,
        backupPath: path,
        backupPassphrase: passphrase,
        fcReason: reason,
      );
}

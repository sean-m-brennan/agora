// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Files in a DM thread, the app's half: what PeerService makes of the core's
// AGORA_EVENT_FILE events, and which verbs it sends to which device. The core
// is not here (an unstarted PeerService, verbs captured through the FileVerbs
// seam); its half is at-social's file_xfer tests and conformance scenarios.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/model/address_book.dart';
import 'package:agora/src/model/file_transfer.dart';
import 'package:agora/src/node/file_verbs.dart';
import 'package:agora/src/node/peer_stream.dart';

List<int> _u(int n) => [for (var i = 0; i < 15; i++) 0, n];
String _h(int n) => hexOf(_u(n));

const _id = '00112233445566778899aabbccddeeff';

AtRawEvent _base(int kind, int who,
        {int fcKind = 0,
        int device = 0,
        String ref = '',
        String petname = '',
        bool blocked = false,
        int dmSeq = 0,
        double dmTs = 0,
        String dmText = ''}) =>
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
      blocked: blocked,
      dmSeq: dmSeq,
      dmTs: dmTs,
      dmText: dmText,
      fcKind: fcKind,
      fcRef: ref,
      fcPetname: petname,
      fcVerified: true,
      fcDeviceUuid: device == 0 ? const [] : _u(device),
    );

AtRawEvent _file(int who, int state,
        {String id = _id,
        bool outgoing = false,
        int size = 1000,
        int done = 0,
        double ts = 100,
        String name = 'notes.txt',
        String path = '',
        String reason = ''}) =>
    AtRawEvent(
      kind: agoraEventFile,
      uuid: _u(who),
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      fileXferId: id,
      fileState: state,
      fileOutgoing: outgoing,
      fileSize: size,
      fileDone: done,
      fileTs: ts,
      fileName: name,
      filePath: path,
      fileReason: reason,
    );

/// Ann is one record (device 1) with a second device (2), both peers.
List<AtRawEvent> _annWithTwoDevices() => [
      _base(agoraEventContact, 1,
          fcKind: atFcContact, ref: refBookList, petname: 'Ann'),
      _base(agoraEventContact, 1,
          fcKind: atFcDeviceLinked, device: 2, ref: refBookList),
      _base(agoraEventContact, 0, fcKind: atFcContactsDone, ref: refBookList),
      _base(agoraEventPeer, 1),
      _base(agoraEventPeer, 2),
    ];

class _Verbs implements FileVerbs {
  final List<String> calls = [];
  int rc = 0;

  @override
  int offer(List<int> deviceUuid, String xferId, String path) {
    calls.add('offer ${hexOf(deviceUuid)} $xferId');
    return rc;
  }

  @override
  int accept(List<int> deviceUuid, String xferId) {
    calls.add('accept ${hexOf(deviceUuid)} $xferId');
    return rc;
  }

  @override
  int decline(List<int> deviceUuid, String xferId) {
    calls.add('decline ${hexOf(deviceUuid)} $xferId');
    return rc;
  }

  @override
  int cancel(List<int> deviceUuid, String xferId) {
    calls.add('cancel ${hexOf(deviceUuid)} $xferId');
    return rc;
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('agora_files_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
      'an incoming offer lands in the thread, unread, and Accept goes to '
      'the device that offered it', () {
    final verbs = _Verbs();
    final svc = PeerService(fileVerbs: verbs);
    svc.ingestEvents([_file(7, agoraFileOffered, size: 2100)]);
    final peer = svc.peers.single;
    final t = svc.filesFor(peer).single;
    expect(t.outgoing, isFalse);
    expect(t.state, FileTransferState.offered);
    expect(t.name, 'notes.txt');
    expect(t.size, 2100);
    expect(svc.hasUnread(peer), isTrue);

    expect(svc.acceptFile(t), 0);
    expect(verbs.calls, ['accept ${_h(7)} $_id']);
    expect(t.state, FileTransferState.accepted);
    // Accepting twice sends nothing more.
    expect(svc.acceptFile(t), -1);
    expect(verbs.calls, hasLength(1));
  });

  test('progress and the end arrive as events, with the finished path', () {
    final svc = PeerService(fileVerbs: _Verbs());
    svc.ingestEvents([
      _file(7, agoraFileOffered, size: 2100),
      _file(7, agoraFileAccepted, size: 2100, done: 1024),
    ]);
    final t = svc.filesFor(svc.peers.single).single;
    expect(t.progress, closeTo(1024 / 2100, 1e-9));
    svc.ingestEvents([
      _file(7, agoraFileDone,
          size: 2100, done: 2100, path: '/data/var/agora/files/notes.txt'),
    ]);
    expect(t.state, FileTransferState.done);
    expect(t.progress, 1.0);
    expect(t.path, '/data/var/agora/files/notes.txt');
  });

  test('a failure carries its reason', () {
    final svc = PeerService(fileVerbs: _Verbs());
    svc.ingestEvents([
      _file(7, agoraFileOffered),
      _file(7, agoraFileFailed, reason: 'hash_mismatch'),
    ]);
    final t = svc.filesFor(svc.peers.single).single;
    expect(t.state, FileTransferState.failed);
    expect(t.reason, 'hash_mismatch');
    expect(t.state.isTerminal, isTrue);
  });

  test(
      'an offer is one transfer to every device of the person, and the '
      'first to accept gets it', () {
    final verbs = _Verbs();
    final svc = PeerService(fileVerbs: verbs);
    svc.ingestEvents(_annWithTwoDevices());
    final ann = svc.peers.single;
    final src = File('${tmp.path}/photo.jpg')
      ..writeAsBytesSync(List.filled(500, 7));

    expect(svc.offerFile(ann, src.path), 0);
    final t = svc.filesFor(ann).single;
    expect(t.outgoing, isTrue);
    expect(t.name, 'photo.jpg');
    expect(t.size, 500);
    expect(verbs.calls, ['offer ${_h(1)} ${t.id}', 'offer ${_h(2)} ${t.id}']);
    expect(t.id, matches(RegExp(r'^[0-9a-f]{32}$')));

    // Her second device takes it: the first device's offer is withdrawn.
    verbs.calls.clear();
    svc.ingestEvents([
      _file(2, agoraFileAccepted, id: t.id, outgoing: true, size: 500, done: 0),
    ]);
    expect(verbs.calls, ['cancel ${_h(1)} ${t.id}']);
    expect(t.state, FileTransferState.accepted);
    svc.ingestEvents([
      _file(1, agoraFileCancelled, id: t.id, outgoing: true, size: 500),
      _file(2, agoraFileDone, id: t.id, outgoing: true, size: 500, done: 500),
    ]);
    expect(t.state, FileTransferState.done);
    expect(t.progress, 1.0);
  });

  test('cancel goes to every device the transfer is still live on', () {
    final verbs = _Verbs();
    final svc = PeerService(fileVerbs: verbs);
    svc.ingestEvents(_annWithTwoDevices());
    final ann = svc.peers.single;
    final src = File('${tmp.path}/a.bin')..writeAsBytesSync([1, 2, 3]);
    svc.offerFile(ann, src.path);
    final t = svc.filesFor(ann).single;
    svc.ingestEvents([_file(1, agoraFileDeclined, id: t.id, outgoing: true)]);
    verbs.calls.clear();
    svc.cancelFile(t);
    expect(verbs.calls, ['cancel ${_h(2)} ${t.id}']);
    expect(t.state, FileTransferState.cancelled);
  });

  test('nothing is offered that is not a readable file', () {
    final verbs = _Verbs();
    final svc = PeerService(fileVerbs: verbs);
    svc.ingestEvents([_base(agoraEventPeer, 7)]);
    final peer = svc.peers.single;
    expect(svc.offerFile(peer, '${tmp.path}/missing'), -1);
    expect(svc.offerFile(peer, tmp.path), -1); // a directory
    expect(svc.filesFor(peer), isEmpty);
    expect(verbs.calls, isEmpty);
  });

  test("a blocked person's offer is dropped and counted", () {
    final svc = PeerService(fileVerbs: _Verbs());
    svc.ingestEvents([
      _base(agoraEventPeer, 7, blocked: true),
      _file(7, agoraFileOffered),
    ]);
    expect(svc.filesFor(svc.peers.single), isEmpty);
    expect(svc.filesDroppedFromBlocked, 1);
  });

  test('the thread interleaves messages and files by time', () {
    final svc = PeerService(fileVerbs: _Verbs());
    svc.ingestEvents([
      _base(agoraEventDm, 7, dmSeq: 1, dmTs: 50, dmText: 'first'),
      _file(7, agoraFileOffered, ts: 60),
      _base(agoraEventDm, 7, dmSeq: 2, dmTs: 70, dmText: 'after the file'),
    ]);
    final items = svc.threadItems(svc.peers.single);
    expect(items.map((i) => i.message?.text ?? 'FILE ${i.file!.name}'),
        ['first', 'FILE notes.txt', 'after the file']);
  });
}

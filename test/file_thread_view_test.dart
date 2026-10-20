// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Widget tests for files in the DM thread: a drop (or the paperclip) asks
// before offering, an incoming offer can be accepted or declined, and a file
// that arrived can be opened, shown or saved. An unstarted PeerService with
// the FileVerbs seam stands in for the core.

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/model/file_transfer.dart';
import 'package:agora/src/node/file_verbs.dart';
import 'package:agora/src/node/peer_stream.dart';
import 'package:agora/src/ui/dm_thread.dart';

const _id = '00112233445566778899aabbccddeeff';
final _u7 = List<int>.filled(16, 7);

AtRawEvent _peerEv() => AtRawEvent(
      kind: agoraEventPeer,
      uuid: _u7,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
    );

AtRawEvent _file(int state, {int done = 0, String path = ''}) => AtRawEvent(
      kind: agoraEventFile,
      uuid: _u7,
      signingPubkey: const [],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: const [],
      repScore: 0,
      repRated: false,
      rttMs: 0,
      fileXferId: _id,
      fileState: state,
      fileSize: 2048,
      fileDone: done,
      fileTs: 10,
      fileName: 'report.pdf',
      filePath: path,
    );

class _Verbs implements FileVerbs {
  final List<String> calls = [];
  @override
  int offer(List<int> deviceUuid, String xferId, String path) {
    calls.add('offer ${path.split('/').last}');
    return 0;
  }

  @override
  int accept(List<int> deviceUuid, String xferId) {
    calls.add('accept $xferId');
    return 0;
  }

  @override
  int decline(List<int> deviceUuid, String xferId) {
    calls.add('decline $xferId');
    return 0;
  }

  @override
  int cancel(List<int> deviceUuid, String xferId) {
    calls.add('cancel $xferId');
    return 0;
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('agora_drop_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, PeerService svc,
      {Future<List<String>> Function()? pick}) {
    return tester.pumpWidget(MaterialApp(
      home: DmThreadPage(
        peer: svc.peers.single,
        service: svc,
        pickFiles: pick ?? () async => const [],
      ),
    ));
  }

  testWidgets('an incoming offer shows Accept and Decline, and Accept sends',
      (tester) async {
    final verbs = _Verbs();
    final svc = PeerService(fileVerbs: verbs)
      ..ingestEvents([_file(agoraFileOffered)]);
    await pump(tester, svc);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pump();
    expect(verbs.calls, ['accept $_id']);
    // Now under way: no more Accept, a Cancel instead.
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets(
      'progress shows while under way, and a received file can be '
      'opened, shown or saved', (tester) async {
    final svc = PeerService(fileVerbs: _Verbs())
      ..ingestEvents(
          [_file(agoraFileOffered), _file(agoraFileAccepted, done: 1024)]);
    await pump(tester, svc);
    final bar = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(0.5, 1e-9));
    expect(find.text('1.0 KB of 2.0 KB'), findsOneWidget);

    svc.ingestEvents([_file(agoraFileDone, done: 2048, path: '/x/report.pdf')]);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Show in folder'), findsOneWidget);
    expect(find.text('Save as…'), findsOneWidget);
  });

  testWidgets('a drop asks first, skips folders, then offers each file',
      (tester) async {
    final verbs = _Verbs();
    final svc = PeerService(fileVerbs: verbs)..ingestEvents([_peerEv()]);
    final a = File('${tmp.path}/a.txt')..writeAsStringSync('a');
    final b = File('${tmp.path}/b.txt')..writeAsStringSync('bb');
    final dir = Directory('${tmp.path}/folder')..createSync();
    await pump(tester, svc);

    final target = tester.widget<DropTarget>(find.byType(DropTarget));
    target.onDragEntered!(DropEventDetails(
        localPosition: Offset.zero, globalPosition: Offset.zero));
    await tester.pump();
    expect(find.byKey(const ValueKey('drop-highlight')), findsOneWidget);

    target.onDragDone!(DropDoneDetails(
      files: [
        DropItemFile(a.path),
        DropItemFile(b.path),
        DropItemDirectory(dir.path, const [])
      ],
      localPosition: Offset.zero,
      globalPosition: Offset.zero,
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('drop-highlight')), findsNothing);
    expect(find.textContaining('Send 2 files to'), findsOneWidget);
    expect(find.textContaining('1 folder skipped'), findsOneWidget);
    expect(verbs.calls, isEmpty); // nothing before the person says so

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    expect(verbs.calls, ['offer a.txt', 'offer b.txt']);
    expect(find.text('a.txt'), findsOneWidget);
    expect(find.text('b.txt'), findsOneWidget);
    expect(find.textContaining('Waiting for'), findsNWidgets(2));
  });

  testWidgets('cancelling the confirmation offers nothing', (tester) async {
    final verbs = _Verbs();
    final svc = PeerService(fileVerbs: verbs)..ingestEvents([_peerEv()]);
    final a = File('${tmp.path}/a.txt')..writeAsStringSync('a');
    await pump(tester, svc);
    tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
        DropDoneDetails(
            files: [DropItemFile(a.path)],
            localPosition: Offset.zero,
            globalPosition: Offset.zero));
    await tester.pumpAndSettle();
    expect(find.textContaining('Send 1 file to'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(verbs.calls, isEmpty);
    expect(svc.filesFor(svc.peers.single), isEmpty);
  });

  testWidgets('the paperclip picks files through the same confirmation',
      (tester) async {
    final verbs = _Verbs();
    final svc = PeerService(fileVerbs: verbs)..ingestEvents([_peerEv()]);
    final a = File('${tmp.path}/notes.md')..writeAsStringSync('# hi');
    await pump(tester, svc, pick: () async => [a.path]);
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    expect(verbs.calls, ['offer notes.md']);
    expect(
        svc.filesFor(svc.peers.single).single.state, FileTransferState.offered);
  });

  testWidgets('an offer too large to take says so and offers no Accept',
      (tester) async {
    final svc = PeerService(fileVerbs: _Verbs())
      ..ingestEvents([_file(agoraFileTooLarge)]);
    await pump(tester, svc);
    expect(find.text('Too large to receive here'), findsOneWidget);
    expect(find.text('Accept'), findsNothing);
  });

  testWidgets('a declined offer reads as declined on the sending side',
      (tester) async {
    final svc = PeerService(fileVerbs: _Verbs())..ingestEvents([_peerEv()]);
    final a = File('${tmp.path}/a.txt')..writeAsStringSync('a');
    svc.offerFile(svc.peers.single, a.path);
    final t = svc.filesFor(svc.peers.single).single;
    svc.ingestEvents([
      AtRawEvent(
        kind: agoraEventFile,
        uuid: _u7,
        signingPubkey: const [],
        rank: 0,
        operatorBound: false,
        operatorAttestedAt: 0,
        operatorPubkey: const [],
        repScore: 0,
        repRated: false,
        rttMs: 0,
        fileXferId: t.id,
        fileState: agoraFileDeclined,
        fileOutgoing: true,
        fileSize: 1,
        fileName: 'a.txt',
      ),
    ]);
    await pump(tester, svc);
    expect(find.textContaining('declined'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });
}

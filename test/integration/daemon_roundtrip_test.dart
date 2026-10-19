// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Integration test: drives the REAL native layer end-to-end — spawns the
// `agorad` daemon, loads `libagora_shim` over dart:ffi, opens the app-events
// queue, and round-trips the app->AT verbs. This is what covers the FFI surface
// (at_events_bindings.dart) and PeerService.start()/_tick/shutdown, which the
// pure-Dart unit tests deliberately cannot touch.
//
// Runs on the Dart VM under `flutter test` (no display needed). It SELF-SKIPS
// unless the native artifacts are wired via env, so the ordinary pure-Dart
// suite is unaffected. `test.sh` sets these when native/build exists:
//   AGORA_SHIM_PATH   -> native/build/libagora_shim.so   (.dylib on macOS; dlopen'd by the shim loader)
//   AGORA_DAEMON_PATH -> native/build/agorad             (spawned by AgoraDaemon)
//   LD_LIBRARY_PATH   includes native/build/at_core      (Linux only; on macOS the
//                     build-tree rpath finds libautonomous_trust)
// Build first with ./build.sh (or cmake -S native -B native/build).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_peer.dart';
import 'package:agora/src/node/agora_daemon.dart';
import 'package:agora/src/node/peer_stream.dart';

String? _skipReason() {
  final shim = Platform.environment['AGORA_SHIM_PATH'];
  final daemon = Platform.environment['AGORA_DAEMON_PATH'];
  if (shim == null || shim.isEmpty || !File(shim).existsSync()) {
    return 'native layer not wired: set AGORA_SHIM_PATH (build with ./build.sh, '
        'run via ./test.sh which exports it)';
  }
  if (daemon == null || daemon.isEmpty || !File(daemon).existsSync()) {
    return 'native layer not wired: set AGORA_DAEMON_PATH';
  }
  return null;
}

void main() {
  final skip = _skipReason();

  group('agorad + shim round-trip', () {
    late Directory root;
    late PeerService svc;

    setUp(() {
      // A SHORT root: AT roots each AF_UNIX socket at $root/var/at/<name>, and
      // sun_path is capped at 108 bytes (104 on macOS).
      root = Directory.systemTemp.createTempSync('agora_it_');
      svc = PeerService(
        daemon: AgoraDaemon(
          queues: AgoraQueues.forThisInstance(),
          root: root.path,
        ),
        pollInterval: const Duration(milliseconds: 150),
      );
    });

    tearDown(() async {
      await svc.shutdown();
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        /* best effort */
      }
    });

    test('starts the daemon, connects, and round-trips set-profile', () async {
      await svc.start();

      // The daemon binds its queue asynchronously after fork; wait for the
      // service to report a connected channel (start() already retries the
      // open, but give the whole handshake a generous window).
      for (var i = 0; i < 100 && svc.status != 'connected'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      expect(svc.status, 'connected',
          reason: 'the daemon should come up and the event queue should open');

      // Round-trip the app->AT verbs over the shim (agora_set_position /
      // agora_set_profile through dart:ffi). 0 == accepted; -2 == AT_APP_NOT_READY,
      // the documented transient while the daemon finishes binding its receive
      // queue (a caller retries, not an error). We retry toward 0 but accept -2
      // as a defined outcome — the ffi path is exercised either way, which is the
      // point of this test; discovery (peer events) needs the netns cohort.
      int pos = -2, prof = -2;
      for (var i = 0; i < 60 && !(pos == 0 && prof == 0); i++) {
        pos = svc.setOwnPosition('u4pruy');
        prof = svc.setOwnProfile(
            {'display_name': 'Integration', 'handle': 'it_node'});
        if (pos == 0 && prof == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(pos, anyOf(0, -2), reason: 'set-position must be a defined shim rc');
      expect(prof, anyOf(0, -2), reason: 'set-profile must be a defined shim rc');
      expect(svc.ownProfile, isNotNull);

      // Exercise the connection FFI wrappers (Increment 5): agora_connect_request
      // / agora_connect_respond through dart:ffi. A single node has no real peer,
      // so the core drops these as "unknown peer"; the point is that the app->AT
      // connect verbs traverse the ffi + shim + dispatch path and return a
      // defined rc (0 accepted, -2 not-ready).
      final synthetic = AgoraPeer(uuid: List<int>.filled(16, 0xAB));
      int creq = -2, cresp = -2;
      for (var i = 0; i < 20 && !(creq == 0 && cresp == 0); i++) {
        creq = svc.requestConnection(synthetic);
        cresp = svc.respondConnection(synthetic, true);
        if (creq == 0 && cresp == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      expect(creq, anyOf(0, -2), reason: 'connect-request must be a defined rc');
      expect(cresp, anyOf(0, -2), reason: 'connect-respond must be a defined rc');

      // Exercise the DM FFI wrapper (Increment 6): agora_send_dm through
      // dart:ffi. A single node has no real peer, so the core drops it as
      // "unknown peer"; the point is the app->AT send-dm verb traverses the ffi +
      // shim + dispatch path and returns a defined rc (0 accepted, -2 not-ready).
      int dmRc = -2;
      for (var i = 0; i < 20 && dmRc != 0; i++) {
        dmRc = svc.sendDm(synthetic, 'hello over ffi');
        if (dmRc == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      expect(dmRc, anyOf(0, -2), reason: 'send-dm must be a defined rc');
      // The outgoing message is echoed locally regardless of the wire rc.
      expect(svc.messagesFor(synthetic).where((m) => m.outgoing), isNotEmpty);

      // Exercise the co-signing FFI wrappers (Phase 3 P3.3): agora_request_cosign
      // / agora_return_cosign through dart:ffi. A single node has no real peer,
      // so the core drops these as "unknown peer"; the point is that the app->AT
      // verbs traverse the ffi + shim + dispatch path and return a defined rc.
      // The payload is a minimal well-formed exchange: the shim refuses an
      // unknown op or a non-hex payload before it reaches the queue, so passing
      // junk here would test the refusal rather than the path.
      int askRc = -2, retRc = -2;
      for (var i = 0; i < 20 && !(askRc == 0 && retRc == 0); i++) {
        askRc = svc.requestCosign(
          [synthetic],
          record: 'guardian',
          op: 'designate',
          polityDid: 'did:key:zTestPolity',
          cid: 'b3:${'0' * 64}',
          bytes: 'a1626f70',
        );
        retRc = svc.returnCosign(
          synthetic,
          cid: 'b3:${'0' * 64}',
          signerDid: 'did:key:zTestSigner',
          sigHex: '0' * 128,
        );
        if (askRc == 0 && retRc == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      expect(askRc, anyOf(0, -2), reason: 'request-cosign must be a defined rc');
      expect(retRc, anyOf(0, -2), reason: 'return-cosign must be a defined rc');

      // And the shim's own refusals, which never reach the queue: an unknown op
      // and a payload no exporter produced. These are worth pinning here because
      // a malformed ask that got through would interrupt somebody to look at a
      // record that cannot become one.
      expect(
        svc.requestCosign([synthetic],
            record: 'guardian',
            op: 'abolish',
            polityDid: 'did:key:zTestPolity',
            cid: 'b3:${'0' * 64}',
            bytes: 'a1626f70'),
        -1,
        reason: 'an unknown op is refused by the shim, not carried',
      );
      expect(
        svc.requestCosign([synthetic],
            record: 'membership',
            op: 'admit',
            polityDid: 'did:key:zTestPolity',
            cid: 'b3:${'0' * 64}',
            bytes: 'not hex'),
        -1,
        reason: 'a payload that is not even hex is refused, not truncated',
      );

      // Let a few poll ticks run (agora_events_poll over ffi). A single node has
      // no peers, so the roster stays empty.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(svc.peers, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 45)));
  }, skip: skip);
}

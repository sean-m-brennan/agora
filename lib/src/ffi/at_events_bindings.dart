// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// dart:ffi bindings for the fork-free AutonomousTrust app-events client,
// exposed through the flat shim in native/at_agora_shim.{h,c}.
//
// Only the client subset (open/poll/request_roster/close) is bound — all
// AF_UNIX socket I/O, no fork(). The heavy AT node runs in the separate
// `agorad` process (see node/agora_daemon.dart).

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const int agoraUuidLen = 16;
const int agoraKeyLen = 32;

const int agoraEventPeer = 1;
const int agoraEventReputation = 2;

/// dart:ffi mirror of `agora_event_t` (native/at_agora_shim.h). Field order and
/// element counts MUST match the C struct exactly — the layout is the ABI
/// contract, and the C side asserts the lengths against AT's own constants.
final class AgoraEvent extends Struct {
  @Int32()
  external int kind;

  @Array(agoraUuidLen)
  external Array<Uint8> peerUuid;

  @Array(agoraKeyLen)
  external Array<Uint8> signingPubkey;

  @Int32()
  external int rank;

  @Uint8()
  external int operatorBound;

  @Double()
  external double operatorAttestedAt;

  @Array(agoraKeyLen)
  external Array<Uint8> operatorPubkey;

  @Double()
  external double repScore;

  @Uint8()
  external int repRated;
}

/// A pure-Dart copy of one decoded event. Decoupled from native memory so it
/// survives after the poll buffer is freed.
class AtRawEvent {
  AtRawEvent({
    required this.kind,
    required this.uuid,
    required this.signingPubkey,
    required this.rank,
    required this.operatorBound,
    required this.operatorAttestedAt,
    required this.operatorPubkey,
    required this.repScore,
    required this.repRated,
  });

  final int kind;
  final List<int> uuid;
  final List<int> signingPubkey;
  final int rank;
  final bool operatorBound;
  final double operatorAttestedAt;
  final List<int> operatorPubkey;
  final double repScore;
  final bool repRated;
}

typedef _SetRootC = Void Function(Pointer<Utf8>);
typedef _SetRootDart = void Function(Pointer<Utf8>);

typedef _OpenC = Pointer<Void> Function(Pointer<Utf8>);
typedef _OpenDart = Pointer<Void> Function(Pointer<Utf8>);

typedef _RosterC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _RosterDart = int Function(Pointer<Void>, Pointer<Utf8>);

typedef _PollC = Int32 Function(Pointer<Void>, Pointer<AgoraEvent>, Int32);
typedef _PollDart = int Function(Pointer<Void>, Pointer<AgoraEvent>, int);

typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

DynamicLibrary _loadShim() {
  final override = Platform.environment['AGORA_SHIM_PATH'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isLinux || Platform.isMacOS) {
    final base = Platform.isMacOS ? 'libagora_shim.dylib' : 'libagora_shim.so';
    // Bundled build: the shim ships in the app's lib/ dir, next to the
    // executable (linux/CMakeLists.txt install rules). Load it by explicit path
    // so it resolves without LD_LIBRARY_PATH; its $ORIGIN rpath then finds
    // libautonomous_trust in the same dir.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir/lib/$base';
    if (File(bundled).existsSync()) return DynamicLibrary.open(bundled);
    // Dev fallback: rely on the loader search path (RUNPATH / LD_LIBRARY_PATH).
    return DynamicLibrary.open(base);
  }
  throw UnsupportedError(
      'Agora native shim: unsupported platform ${Platform.operatingSystem}');
}

List<int> _copyArray(Array<Uint8> src, int len) =>
    List<int>.generate(len, (i) => src[i], growable: false);

/// Thin, fork-free client over the AutonomousTrust app-events queue.
class AtEvents {
  AtEvents._(this._handle);

  final Pointer<Void> _handle;

  static final DynamicLibrary _lib = _loadShim();
  static final _SetRootDart _setRoot =
      _lib.lookupFunction<_SetRootC, _SetRootDart>('agora_set_root');
  static final _OpenDart _open =
      _lib.lookupFunction<_OpenC, _OpenDart>('agora_events_open');
  static final _RosterDart _roster = _lib
      .lookupFunction<_RosterC, _RosterDart>('agora_events_request_roster');
  static final _PollDart _poll =
      _lib.lookupFunction<_PollC, _PollDart>('agora_events_poll');
  static final _CloseDart _close =
      _lib.lookupFunction<_CloseC, _CloseDart>('agora_events_close');

  /// Point this process's AutonomousTrust config root at [root], so the queue
  /// sockets opened below resolve under the same `$root/var/at/` the `agorad`
  /// daemon uses. Must be called before [open]. No-op for an empty root.
  static void setRoot(String root) {
    if (root.isEmpty) return;
    final p = root.toNativeUtf8();
    try {
      _setRoot(p);
    } finally {
      calloc.free(p);
    }
  }

  /// Open the AT->app receive queue (a bare name, e.g. "at_to_extern"). Returns
  /// null if it cannot be bound.
  static AtEvents? open(String recvQueue) {
    final namePtr = recvQueue.toNativeUtf8();
    try {
      final h = _open(namePtr);
      if (h == nullptr) return null;
      return AtEvents._(h);
    } finally {
      calloc.free(namePtr);
    }
  }

  /// Ask the daemon to (re)send the roster on the app->AT queue. Returns 0 on
  /// success, negative on error (-2 == daemon not ready yet).
  int requestRoster(String sendQueue) {
    final p = sendQueue.toNativeUtf8();
    try {
      return _roster(_handle, p);
    } finally {
      calloc.free(p);
    }
  }

  /// Non-blocking drain. Returns decoded events (possibly empty). Copies out of
  /// native memory before freeing the buffer, so the results are safe to keep.
  List<AtRawEvent> poll({int max = 64}) {
    final buf = calloc<AgoraEvent>(max);
    try {
      final n = _poll(_handle, buf, max);
      if (n <= 0) return const [];
      return List<AtRawEvent>.generate(n, (i) {
        final e = buf[i];
        return AtRawEvent(
          kind: e.kind,
          uuid: _copyArray(e.peerUuid, agoraUuidLen),
          signingPubkey: _copyArray(e.signingPubkey, agoraKeyLen),
          rank: e.rank,
          operatorBound: e.operatorBound != 0,
          operatorAttestedAt: e.operatorAttestedAt,
          operatorPubkey: _copyArray(e.operatorPubkey, agoraKeyLen),
          repScore: e.repScore,
          repRated: e.repRated != 0,
        );
      }, growable: false);
    } finally {
      calloc.free(buf);
    }
  }

  void close() => _close(_handle);
}

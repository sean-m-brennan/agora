// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// FileTransfer: one file in a DM thread. The core moves the bytes; the app
// sees only what the AGORA_EVENT_FILE events say (offer, answer, progress,
// end) and keeps the thread's view of it here.
//
// One OUTGOING transfer is offered to every device of the person, under one
// id, so it is one bubble with a state per device. Once any device accepts,
// PeerService cancels the offer on the rest, so the file arrives once.

import 'dm.dart';

/// Mirrors AGORA_FILE_* (at_agora_shim.h); the index IS the wire value.
enum FileTransferState {
  offered,
  accepted,
  done,
  declined,
  cancelled,
  failed,
  tooLarge;

  static FileTransferState fromWire(int v) =>
      v >= 0 && v < values.length ? values[v] : FileTransferState.failed;

  bool get isTerminal =>
      this != FileTransferState.offered && this != FileTransferState.accepted;
}

class FileTransfer {
  FileTransfer({
    required this.id,
    required this.peerUuidHex,
    required this.name,
    required this.size,
    required this.outgoing,
    required this.ts,
    this.path = '',
  });

  /// 32 hex; with the person, names the transfer.
  final String id;

  /// The device that offered it (incoming), or the first one we offered it to
  /// (outgoing).
  final String peerUuidHex;

  /// A bare file name (the core sanitized an incoming one).
  String name;
  int size;
  final bool outgoing;

  /// When it was offered, epoch seconds. Orders it among the DMs.
  final double ts;

  /// Outgoing: the source. Incoming: the finished file once [state] is done.
  String path;

  /// A token on failed ("hash_mismatch", "source_changed", ...).
  String reason = '';

  /// Bytes held (incoming) or served (outgoing).
  int bytesDone = 0;

  /// Outgoing: each device's own state, by uuid hex. Incoming: the one device.
  final Map<String, FileTransferState> deviceStates = {};

  /// The state to show. Incoming, the device's own. Outgoing, the furthest
  /// any device got: done, else under way, else still offered, else why it
  /// ended (failed before cancelled before declined).
  FileTransferState get state {
    if (deviceStates.isEmpty) return FileTransferState.offered;
    const order = [
      FileTransferState.done,
      FileTransferState.accepted,
      FileTransferState.offered,
      FileTransferState.failed,
      FileTransferState.tooLarge,
      FileTransferState.cancelled,
      FileTransferState.declined,
    ];
    for (final s in order) {
      if (deviceStates.containsValue(s)) return s;
    }
    return FileTransferState.failed;
  }

  /// 0..1; 1 for an empty file.
  double get progress =>
      size <= 0 ? 1.0 : (bytesDone / size).clamp(0.0, 1.0).toDouble();
}

/// One entry in a DM thread: a message or a file, ordered by [ts].
class ThreadItem {
  const ThreadItem.message(DmMessage this.message) : file = null;
  const ThreadItem.file(FileTransfer this.file) : message = null;

  final DmMessage? message;
  final FileTransfer? file;

  double get ts => message?.ts ?? file!.ts;
  bool get outgoing => message?.outgoing ?? file!.outgoing;
}

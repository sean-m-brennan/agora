// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// DmMessage: one direct message in a peer thread (Increment 6). A DM is a single
// directed, ENCRYPTED, one-way peer→peer text message. Incoming messages arrive
// from the AT core (AT_APP_EVENT_DM, already sender-authenticated by crypto_box);
// outgoing messages are echoed locally at send time (the core does NOT echo them
// back). The thread is a LIVE STREAM, kept per-peer in PeerService — not roster
// state.

/// One direct message, incoming or outgoing.
class DmMessage {
  const DmMessage({
    required this.peerUuidHex,
    required this.seq,
    required this.ts,
    required this.text,
    required this.outgoing,
  });

  /// The OTHER party's uuid (hex), i.e. the sender for an incoming message and
  /// the recipient for an outgoing one — so a thread groups by this key either
  /// way.
  final String peerUuidHex;

  /// Freshness sequence. For incoming messages this is the sender's seq (the
  /// replay-guard value the core accepted); for locally-echoed outgoing messages
  /// it is 0 (the core stamps the real wire seq, which never returns to the app).
  final int seq;

  /// Send time in epoch seconds (the sender's clock for incoming; local time for
  /// outgoing).
  final double ts;

  /// The message body.
  final String text;

  /// True if this node sent it (render right), false if received (render left).
  final bool outgoing;
}

// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The polity acts an expulsion needs, behind one seam (Phase 4 P4.1): open the
// exchange, sign this node's own share, assemble the signatures into the log,
// and read the log back. In the app these are the Ethne cdylib over the charter
// archive; in a test they are plain Dart, so the whole flow — and in particular
// its ORDER — is exercised with no library present.

/// Throws on refusal, with the library's reason as the message.
abstract class PolityActs {
  /// Open an expulsion exchange. Returns pendingChange's map
  /// `{record, op, polity_did, payload, bytes, cid, description,
  /// signers_required}`.
  Map<String, dynamic> pendingExpel({
    required String polityDid,
    required String memberDid,
    required String rationale,
    required List<String> deciderDids,
  });

  /// This node's own detached signature over [bytesHex].
  String signOwn(String bytesHex);

  /// Attach [signatures] to [payload] — exactly as pendingChange returned it —
  /// and append. Throws if a signature does not verify.
  void assemble(Map<String, dynamic> payload,
      List<({String did, String sig})> signatures);

  /// Does the log verify as a whole, after the append?
  bool verify();

  /// The DIDs on the roll of [polityDid] as the log now folds it.
  List<String> rollDids(String polityDid);

  /// The log, for persisting after an append.
  Map<String, dynamic> dump();
}

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

/// The roll acts behind a community's content policy (Phase 4, Ethne D37): the
/// roll replacing its policy, and conferring or revoking the Moderator office.
/// Both travel the same detached co-signing exchange an expulsion does — the
/// record's bytes move, the deciders' keys do not — under the record classes
/// `content_policy` and `office`.
///
/// A separate interface from [PolityActs] so an expulsion-only fake need not
/// grow; the production implementation serves both.
/// The roll's compact acts (SOCIAL_APP_PLAN Phase 5; Ethne D40), on the same
/// detached co-signing exchange, under the record class `compact`. Its own
/// interface so a policy-only fake need not grow.
abstract class CompactGovernance {
  /// Begin a compact act: [kind] is `Join`, `Admit`, `Sponsor`, `Refuse`,
  /// `Anathematize` or `Lift`. A sponsorship names [probationDays].
  Map<String, dynamic> pendingCompactAct({
    required String polityDid,
    required String kind,
    required String compact,
    required List<String> counterparties,
    int? probationDays,
    required String rationale,
    required List<String> deciderDids,
  });
}

abstract class CommunityGovernance {
  /// Begin replacing the policy of [polityDid] with [policy] (Ethne
  /// `ContentPolicy` JSON). A majority tightens; loosening needs more.
  Map<String, dynamic> pendingPolicy({
    required String polityDid,
    required Map<String, dynamic> policy,
    required String rationale,
    required List<String> deciderDids,
  });

  /// Begin conferring ([confer] true) or revoking Moderator on [holderDid].
  /// A conferral also needs the holder's own signature.
  Map<String, dynamic> pendingModerator({
    required String polityDid,
    required String holderDid,
    required bool confer,
    required String rationale,
    required List<String> deciderDids,
  });

  /// Sign exported bytes with this node's own member key.
  String signOwn(String bytesHex);

  /// Attach [signatures] to [payload] (of record class [record]) and append.
  void assemble(String record, Map<String, dynamic> payload,
      List<({String did, String sig})> signatures);

  /// Every signature and every governance rule, over the whole log.
  bool verify();

  /// `{policy, set_by, moderators}` as this log reads now.
  Map<String, dynamic> policyState(String polityDid);

  /// Mint the policy artifact under the polity's ROOT key, or null when this
  /// node does not hold it.
  String? mintPolicy(String polityDid);

  /// The log, for persisting.
  Map<String, dynamic> dump();
}

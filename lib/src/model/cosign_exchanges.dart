// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Co-signature exchanges in flight (Phase 3 P3.3, SOCIAL_APP_PLAN.md §2.2). A
// governance act that needs several signatures is assembled in two phases so no
// private key ever moves: the asking node exports the canonical bytes, each
// signer signs them on their own node, and the signatures come back.
//
// THE BYTES ARE OPAQUE AND UNVERIFIED HERE. The AT core is a courier for this
// exchange — it holds no Ethne, so it cannot know what the bytes mean, and it
// does not hold the payload, so it cannot check a returned signature. It bounds
// and shape-checks them and nothing more. This model is the same: it stores what
// arrived and proves nothing about it.
//
// AND THE WORDING NEVER ARRIVES WITH THEM. No description crosses the wire, by
// design: a node that chose both what you sign and what you are told you are
// signing could put a friendly sentence over hostile bytes and collect a real
// signature on the end of it. So the description is DERIVED LOCALLY, here, from
// the bytes themselves, through an injected [CosignDescriber] — which is also
// what keeps this model pure and testable with no cdylib present, exactly as
// BusinessDirectory takes its bundle verifier.

import '../ffi/at_events_bindings.dart';

/// Derives what [bytesHex] commits to, on this node, for a `'membership'` or
/// `'guardian'` record. Returns null when it cannot be read as that class — the
/// honest answer for bytes that do not deserialize, and never a guess.
typedef CosignDescriber = Map<String, dynamic>? Function(
    String record, String bytesHex);

/// One inbound request to co-sign an act.
class CosignExchange {
  const CosignExchange({
    required this.requesterUuid,
    required this.record,
    required this.op,
    required this.polityDid,
    required this.cid,
    required this.bytes,
    required this.seq,
    required this.ts,
  });

  /// The peer that asked. Signatures go back to this node and nowhere else.
  final List<int> requesterUuid;

  /// `'membership'` or `'guardian'`.
  final String record;

  /// `'admit'`, `'expel'`, `'designate'`, `'rotate'` or `'release'` — as CLAIMED
  /// by the asker. The locally derived description is what to trust.
  final String op;

  /// The polity the act concerns, as claimed.
  final String polityDid;

  /// The content id of the act, as claimed. Recomputed locally before signing.
  final String cid;

  /// The canonical CBOR of the act, hex. Opaque and unverified at this boundary.
  final String bytes;

  final int seq;
  final double ts;

  factory CosignExchange.fromEvent(AtRawEvent e) => CosignExchange(
        requesterUuid: e.uuid,
        record: e.cosignRecord,
        op: e.cosignOp,
        polityDid: e.cosignPolity,
        cid: e.cosignCid,
        bytes: e.cosignBytes,
        seq: e.cosignSeq,
        ts: e.cosignTs,
      );
}

/// A signature that came back for an act this node asked about.
class CosignSignature {
  const CosignSignature({
    required this.cid,
    required this.signerDid,
    required this.sig,
    required this.ts,
  });

  final String cid;
  final String signerDid;
  final String sig;
  final double ts;

  factory CosignSignature.fromEvent(AtRawEvent e) => CosignSignature(
        cid: e.cosignCid,
        signerDid: e.cosignSignerDid,
        sig: e.cosignSig,
        ts: e.cosignTs,
      );
}

/// The exchanges this node knows about: requests waiting on it, and signatures
/// returned to it. A live stream, not roster state — never re-requested, and
/// dropped on restart.
class CosignExchanges {
  CosignExchanges({required this.describeBytes, this.cap = 64});

  /// Derives the wording locally. Required and without a default, for the same
  /// reason BusinessDirectory.verifyBundle is: defaulting it would quietly turn
  /// "nobody checked" into "it is fine".
  final CosignDescriber describeBytes;

  /// How many pending requests to retain. Oldest are dropped first.
  final int cap;

  final Map<String, CosignExchange> _pending = {};
  final Map<String, List<CosignSignature>> _signatures = {};
  final Set<String> _settled = {};
  final Map<String, Map<String, dynamic>?> _described = {};

  /// Record an inbound request. Returns whether anything changed. A cid already
  /// signed or declined here is not resurrected by a replay of the ask.
  bool addRequest(CosignExchange e) {
    if (e.cid.isEmpty || e.bytes.isEmpty) return false;
    if (_settled.contains(e.cid)) return false;
    // Held by cid, so the same act asked twice is one act. Bytes arriving under
    // a cid already held are NOT merged either: a second payload wearing the
    // first one's cid is the substitution this whole exchange exists to prevent,
    // and the held bytes are the ones a signer was shown.
    if (_pending.containsKey(e.cid)) return false;
    _pending[e.cid] = e;
    _trim();
    return true;
  }

  /// Record a returned signature. Returns whether anything changed.
  bool addSignature(CosignSignature s) {
    if (s.cid.isEmpty || s.signerDid.isEmpty || s.sig.isEmpty) return false;
    final list = _signatures.putIfAbsent(s.cid, () => <CosignSignature>[]);
    if (list.any((x) => x.signerDid == s.signerDid)) return false;
    list.add(s);
    return true;
  }

  /// Requests still waiting on this node, newest first, tie-broken by cid so the
  /// order never depends on incidental map order.
  List<CosignExchange> get pending {
    final out = _pending.values.toList()
      ..sort((a, b) {
        final byTs = b.ts.compareTo(a.ts);
        if (byTs != 0) return byTs;
        return a.cid.compareTo(b.cid);
      });
    return List<CosignExchange>.unmodifiable(out);
  }

  int get pendingCount => _pending.length;

  /// Signatures returned for [cid].
  List<CosignSignature> signaturesFor(String cid) =>
      List<CosignSignature>.unmodifiable(
          _signatures[cid] ?? const <CosignSignature>[]);

  /// What [e] actually commits to, derived on this node from its bytes. Null
  /// when the bytes cannot be read as the record class they claim — which is a
  /// reason to refuse, not to fall back to what the asker said. Memoized: the
  /// derivation is pure in the bytes.
  Map<String, dynamic>? describe(CosignExchange e) =>
      _described.putIfAbsent(e.cid, () {
        try {
          return describeBytes(e.record, e.bytes);
        } on Object {
          return null;
        }
      });

  /// Drop a request once it has been signed or declined. Both outcomes settle
  /// it: having declined once, this node is not asked again by a replay.
  bool settle(String cid) {
    final had = _pending.remove(cid) != null;
    _settled.add(cid);
    _described.remove(cid);
    return had;
  }

  /// Whether this node has already signed or declined [cid].
  bool isSettled(String cid) => _settled.contains(cid);

  final Map<String, AuthoredExchange> _authored = {};

  /// Hold an exchange this node started. Replaces one with the same cid.
  void addAuthored(AuthoredExchange a) => _authored[a.cid] = a;

  /// Exchanges this node started, newest first.
  List<AuthoredExchange> get authored => List<AuthoredExchange>.unmodifiable(
      _authored.values.toList()
        ..sort((a, b) {
          final byTs = b.createdAt.compareTo(a.createdAt);
          return byTs != 0 ? byTs : a.cid.compareTo(b.cid);
        }));

  AuthoredExchange? authoredFor(String cid) => _authored[cid];

  /// Forget a finished exchange this node started.
  bool dropAuthored(String cid) => _authored.remove(cid) != null;

  void _trim() {
    if (_pending.length <= cap) return;
    final byAge = _pending.values.toList()
      ..sort((a, b) {
        final byTs = a.ts.compareTo(b.ts);
        if (byTs != 0) return byTs;
        return a.cid.compareTo(b.cid);
      });
    for (final e in byAge.take(_pending.length - cap)) {
      _pending.remove(e.cid);
      _described.remove(e.cid);
    }
  }
}

/// Where an exchange THIS node started stands (Phase 4 P4.1).
enum AuthoredStatus {
  /// Asked; waiting for signatures to come back.
  collecting,

  /// Assembled, appended, and re-verified: the act is in the log.
  landed,

  /// Assembly or re-verification refused it. Nothing was applied.
  failed,
}

/// An exchange this node is AUTHORING — the other side of [CosignExchange].
///
/// Before P4.1 this app only ever answered an ask, so it held no record of one
/// it made. An expulsion is the first act the app starts itself, and closing
/// it needs exactly what [EthneArchive.pendingChange] returned: the payload
/// must go back to assembly UNCHANGED, because the signatures are over its
/// canonical bytes and a rebuilt payload will not verify.
class AuthoredExchange {
  AuthoredExchange({
    required this.cid,
    required this.record,
    required this.op,
    required this.polityDid,
    required this.memberDid,
    required this.payload,
    required this.bytes,
    required this.description,
    required this.signersRequired,
    required this.createdAt,
    this.targetPeerUuid,
  });

  /// Build from what pendingChange returned, plus what the operator chose.
  factory AuthoredExchange.fromPending(
    Map<String, dynamic> pending, {
    required String memberDid,
    required double createdAt,
    List<int>? targetPeerUuid,
  }) =>
      AuthoredExchange(
        cid: pending['cid'] as String? ?? '',
        record: pending['record'] as String? ?? 'membership',
        op: pending['op'] as String? ?? '',
        polityDid: pending['polity_did'] as String? ?? '',
        memberDid: memberDid,
        // The SAME object when it is already typed, never a copy: this is
        // what goes back to assembly.
        payload: switch (pending['payload']) {
          final Map<String, dynamic> m => m,
          final Map m => m.cast<String, dynamic>(),
          _ => const <String, dynamic>{},
        },
        bytes: pending['bytes'] as String? ?? '',
        description: pending['description'] as String? ?? '',
        signersRequired: ((pending['signers_required'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        createdAt: createdAt,
        targetPeerUuid: targetPeerUuid,
      );

  final String cid;
  final String record;
  final String op;
  final String polityDid;

  /// Who the act is done to.
  final String memberDid;

  /// Exactly as pendingChange returned it. Never rebuilt.
  final Map<String, dynamic> payload;
  final String bytes;

  /// Ethne's own wording, derived from the bytes on this node.
  final String description;

  /// Every DID that must sign. All of them, not a count.
  final List<String> signersRequired;
  final double createdAt;

  /// The peer the operator said IS this member, if any. There is no DID→peer
  /// mapping, so this is a manual pick; the signature check on assembly is the
  /// real gate, so a wrong pick fails safely — it can only misdirect the
  /// reputation consequence, which is why it is applied after the act lands and
  /// is visible in the blocked-and-limited list.
  final List<int>? targetPeerUuid;

  AuthoredStatus status = AuthoredStatus.collecting;

  /// Why it failed, in the library's words, when [status] is failed.
  String? error;

  /// The rc of the standing hand-off after landing, or null if none was made
  /// (no target peer picked).
  int? standingRc;

  /// Signatures that count: one per required signer, the first to arrive.
  List<CosignSignature> countedFrom(List<CosignSignature> arrived) {
    final seen = <String>{};
    return [
      for (final s in arrived)
        if (signersRequired.contains(s.signerDid) && seen.add(s.signerDid)) s,
    ];
  }

  /// Required signers who have not signed yet.
  List<String> missingFrom(List<CosignSignature> arrived) {
    final have = countedFrom(arrived).map((s) => s.signerDid).toSet();
    return signersRequired.where((d) => !have.contains(d)).toList();
  }

  bool readyFrom(List<CosignSignature> arrived) =>
      signersRequired.isNotEmpty && missingFrom(arrived).isEmpty;
}

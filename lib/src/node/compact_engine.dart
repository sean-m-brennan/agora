// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// A staff node's part in its community's kith-covenant compacts (SOCIAL_APP_PLAN
// Phase 5; Ethne D39, D40). The roll decides each compact act in the charter log;
// this carries out what was decided, at KC's border, over Agora's co-sign carrier:
//
//  - a replica of every compact the community sits in, kept in step by
//    DELIVERIES (`kc_record`/`deliver`), each answered with a receipt and re-sent
//    until it is (AT ISSUES §2.32: a send can be lost at a full queue);
//  - SEALS, which never cross the wire: the convener sends a manifest
//    (`kc_seal`/`sign`), each signer's node rebuilds the seal from its own replica
//    and signs only if its roll's act covers it, and the convener sends the
//    sealed note (`kc_seal`/`sealed`) every replica lands;
//  - CONDUCT records (an anathema, its lifting), co-signed by every reporting
//    community (`kc_conduct`/`sign`);
//  - the rite, whose witnesses attest from their own devices (`kc_attest`).
//
// Asks a roll act already decided are answered here, without a person: the
// decision was the roll's, and each answer is checked against it by the cdylib.
// The people-facing asks (roll acts, attestations) go to the ordinary co-signing
// list instead.

import 'dart:convert';

/// The KC border this node holds: its replica, its charter log and its keys.
abstract class CompactBorder {
  String get polityDid;

  /// This node's own member DID (the envoy and Inductor on the governance node; a
  /// seated examiner elsewhere).
  String get selfDid;

  /// Whether this node holds the polity root key (the governance node).
  bool get governs;

  Map<String, dynamic> border();
  /// Draft the KC rite recited by [inductorDid]. KC holds one delegation per
  /// speaker, so the Inductor is never the envoy: a member's Reciter delegation
  /// would replace their Envoy one.
  Map<String, dynamic> riteDraft(String inductorDid);
  Map<String, dynamic> riteSeal(Map<String, dynamic> spec);
  Map<String, dynamic> claims(String compact, List<String> counterparties);
  Map<String, dynamic> verdicts(String compact, String presenter, bool accepted);
  Map<String, dynamic> sponsor(String compact, String entrant);
  Map<String, dynamic> examiners(List<Map<String, dynamic>> seats);
  Map<String, dynamic> sealDraft(String compact, List<String> participants);
  Map<String, dynamic> sealSign(String manifest);
  Map<String, dynamic> sealAssemble(String manifest, List<Map<String, dynamic>> sigs);
  Map<String, dynamic> sealIngest(String sealed);
  Map<String, dynamic> conductDraft(String kind, String compact, List<String> reporters, String subject,
      {String? designation});
  Map<String, dynamic> conductSign(String compact, {Map<String, dynamic>? payload, String? bytes});
  Map<String, dynamic> conductAssemble(Map<String, dynamic> payload, List<Map<String, dynamic>> sigs);
  Map<String, dynamic> ingest(String hex);

  /// Everything the replica holds, as it travels: `[{record, op, cid, hex}]`.
  List<Map<String, dynamic>> deliveries();
  String signOwn(String bytesHex);
  String receiptSign(String cid);
  bool receiptVerify(String cid, String did, String sig);
  String viewSign(String node);
  String dump();
}

/// The co-sign carrier, as the engine uses it. Nodes are AT uuids, 32 hex.
abstract class CompactTransport {
  int ask(List<String> nodes,
      {required String record, required String op, required String cid, required String bytes});
  int answer(String node, {required String cid, required String signerDid, required String sig});

  /// Carry the community's own view (it verifies and keeps it).
  void publishView(String bundle);
}

/// One delivery, re-sent to each recipient until its receipt verifies.
class _Outgoing {
  _Outgoing(this.record, this.op, this.cid, this.hex, this.to);
  final String record;
  final String op;
  final String cid;
  final String hex;

  /// node -> acknowledged
  final Map<String, bool> to;

  Map<String, dynamic> toJson() =>
      {'record': record, 'op': op, 'cid': cid, 'hex': hex, 'to': to};

  static _Outgoing fromJson(Map<String, dynamic> j) => _Outgoing(
        j['record'] as String,
        j['op'] as String,
        j['cid'] as String,
        j['hex'] as String,
        (j['to'] as Map).map((k, v) => MapEntry(k as String, v as bool)),
      );
}

/// A seal this node convened, collecting signatures.
class SealAsk {
  SealAsk(this.compact, this.manifest, this.cid, this.kind, this.sigs);
  final String compact;
  final String manifest;
  final String cid;
  final String kind;

  /// signer DID -> signature hex
  final Map<String, String> sigs;
  bool landed = false;

  Map<String, dynamic> toJson() =>
      {'compact': compact, 'manifest': manifest, 'cid': cid, 'kind': kind, 'sigs': sigs, 'landed': landed};

  static SealAsk fromJson(Map<String, dynamic> j) => SealAsk(
      j['compact'] as String,
      j['manifest'] as String,
      j['cid'] as String,
      j['kind'] as String,
      (j['sigs'] as Map).map((k, v) => MapEntry(k as String, v as String)))
    ..landed = j['landed'] as bool? ?? false;
}

/// A conduct record this node drafted, collecting the reporters' signatures.
class ConductAsk {
  ConductAsk(this.compact, this.payload, this.cid, this.reporters, this.sigs);
  final String compact;
  final Map<String, dynamic> payload;
  final String cid;
  final List<String> reporters;
  final Map<String, String> sigs;
  bool landed = false;

  Map<String, dynamic> toJson() => {
        'compact': compact,
        'payload': payload,
        'cid': cid,
        'reporters': reporters,
        'sigs': sigs,
        'landed': landed,
      };

  static ConductAsk fromJson(Map<String, dynamic> j) => ConductAsk(
      j['compact'] as String,
      (j['payload'] as Map).cast<String, dynamic>(),
      j['cid'] as String,
      [for (final r in j['reporters'] as List) r as String],
      (j['sigs'] as Map).map((k, v) => MapEntry(k as String, v as String)))
    ..landed = j['landed'] as bool? ?? false;
}

/// The rite in flight: the recitation drafted, waiting on its witnesses.
class RiteAsk {
  RiteAsk(this.draft, this.sigs, {required this.inductorDid});
  final Map<String, dynamic> draft;
  final String inductorDid;

  /// The Inductor's signature over the recitation, once it is in.
  String? recitationSig;

  /// witness DID -> signature over its attestation bytes
  final Map<String, String> sigs;

  List<Map<String, dynamic>> get attest =>
      [for (final a in (draft['attest'] as List)) (a as Map).cast<String, dynamic>()];

  Map<String, dynamic> toJson() =>
      {'draft': draft, 'sigs': sigs, 'inductor': inductorDid, 'recitation_sig': recitationSig};
  static RiteAsk fromJson(Map<String, dynamic> j) => RiteAsk((j['draft'] as Map).cast<String, dynamic>(),
      (j['sigs'] as Map).map((k, v) => MapEntry(k as String, v as String)),
      inductorDid: j['inductor'] as String? ?? '')
    ..recitationSig = j['recitation_sig'] as String?;
}

class CompactEngine {
  CompactEngine({
    required this.border,
    required this.transport,
    required this.ownNode,
    required this.members,
    this.onChanged,
  });

  final CompactBorder border;
  final CompactTransport transport;

  /// This node's AT uuid, 32 hex.
  final String ownNode;

  /// Every node a delivery goes to: the other communities' governance nodes and
  /// this community's seated examiners' nodes. Read afresh each time.
  final List<String> Function() members;

  /// Called after anything persistent changed (the caller saves).
  final void Function()? onChanged;

  final Map<String, _Outgoing> _outbox = {};
  final Map<String, SealAsk> seals = {};
  final Map<String, ConductAsk> conducts = {};
  RiteAsk? rite;

  /// Nodes this community's own examiners sit on (besides this one).
  final Set<String> examinerNodes = {};

  /// Communities this one is working with in a compact (named in an act it
  /// carried out), so deliveries reach them before any view lists them.
  final Set<String> partners = {};

  /// The last thing that went wrong, for the UI to show once.
  String? lastError;

  bool _viewStale = true;
  int _ticks = 0;
  static const int resendEveryTicks = 20; // ~6 s at the 300 ms default
  static const int resendPerTick = 8;

  /// Deliveries still waiting on a receipt from some recipient.
  int get unacknowledged => _outbox.values.where((o) => o.to.values.contains(false)).length;

  List<String> _recipients() => {
        for (final n in members()) if (n != ownNode && n.length == 32) n,
        for (final n in examinerNodes) if (n != ownNode) n,
      }.toList();

  void _queue(String record, String op, String cid, String hex) {
    final to = {for (final n in _recipients()) n: false};
    final held = _outbox[cid];
    if (held != null) {
      for (final n in to.keys) {
        held.to.putIfAbsent(n, () => false);
      }
    } else {
      _outbox[cid] = _Outgoing(record, op, cid, hex, to);
    }
    final o = _outbox[cid]!;
    final pending = [for (final e in o.to.entries) if (!e.value) e.key];
    if (pending.isNotEmpty) {
      transport.ask(pending, record: record, op: op, cid: cid, bytes: hex);
    }
  }

  /// Give a recipient that is new (a seated examiner's node, an entrant) every
  /// delivery it missed, now rather than at the next resend: its replica needs
  /// this community's border before it can sign anything for it.
  void _widen() {
    final now = _recipients();
    for (final o in _outbox.values) {
      final fresh = [for (final n in now) if (!o.to.containsKey(n)) n];
      if (fresh.isEmpty) continue;
      for (final n in fresh) {
        o.to[n] = false;
      }
      transport.ask(fresh, record: o.record, op: o.op, cid: o.cid, bytes: o.hex);
    }
  }

  /// Hand this community's examiners' nodes everything the replica holds, other
  /// communities' records included: they rebuild every seal they are asked to sign.
  void _relay() {
    final to = [for (final n in examinerNodes) if (n != ownNode) n];
    if (to.isEmpty) return;
    for (final d in border.deliveries()) {
      final cid = d['cid'] as String;
      final o = _outbox.putIfAbsent(
          cid, () => _Outgoing(d['record'] as String, d['op'] as String, cid, d['hex'] as String, <String, bool>{}));
      final fresh = [for (final n in to) if (!o.to.containsKey(n)) n];
      if (fresh.isEmpty) continue;
      for (final n in fresh) {
        o.to[n] = false;
      }
      transport.ask(fresh, record: o.record, op: o.op, cid: cid, bytes: o.hex);
    }
  }

  /// Hand every delivery a producer returned to the members.
  void _deliver(Map<String, dynamic> out) {
    for (final d in (out['deliveries'] as List? ?? const [])) {
      final m = (d as Map).cast<String, dynamic>();
      _queue('kc_record', 'deliver', m['cid'] as String, m['hex'] as String);
    }
    _viewStale = true;
    onChanged?.call();
  }

  bool _try(void Function() f) {
    lastError = null;
    try {
      f();
      return true;
    } on Object catch (e) {
      lastError = '$e';
      return false;
    }
  }

  // --- actions (the staff UI drives these, after the roll's acts) ------------

  /// Publish the identity and envoy, and draft the rite recited by [inductorDid]
  /// (never this node's envoy: KC holds one delegation per speaker). The
  /// Inductor and each witness on another device are asked through
  /// [witnessNodes]; only the member an ask names can sign it, so every ask may go
  /// to all of them.
  bool crossBorder({required String inductorDid, List<String> witnessNodes = const []}) => _try(() {
        if (inductorDid == border.selfDid) {
          throw StateError('the Inductor is not the envoy: KC holds one delegation per speaker');
        }
        _deliver(border.border());
        final draft = border.riteDraft(inductorDid);
        _deliver(draft);
        final ask = RiteAsk(draft, {}, inductorDid: inductorDid);
        rite = ask; // before any ask goes out: an answer may come back at once
        if (witnessNodes.isNotEmpty) {
          transport.ask(witnessNodes,
              record: 'kc_attest',
              op: 'recite',
              cid: _reciteCid(inductorDid),
              bytes: draft['recitation_bytes'] as String);
        }
        for (final a in ask.attest) {
          final w = a['witness_did'] as String;
          if (w == border.selfDid) {
            ask.sigs[w] = border.signOwn(a['bytes'] as String);
            continue;
          }
          if (witnessNodes.isEmpty) continue;
          transport.ask(witnessNodes,
              record: 'kc_attest', op: 'attest', cid: _attestCid(a), bytes: a['bytes'] as String);
        }
        _maybeSealRite();
        onChanged?.call();
      });

  static String _reciteCid(String did) => 'recite:${did.substring(did.length - 16)}';

  static String _attestCid(Map<String, dynamic> a) =>
      'attest:${(a['witness_did'] as String).substring((a['witness_did'] as String).length - 16)}';

  void _maybeSealRite() {
    final r = rite;
    if (r == null || r.recitationSig == null) return;
    if (r.attest.any((a) => !r.sigs.containsKey(a['witness_did']))) return;
    final out = border.riteSeal({
      'polity_did': border.polityDid,
      'recitation': r.draft['recitation'],
      'recitation_sig': {'did': r.inductorDid, 'sig': r.recitationSig},
      'attestations': [
        for (final a in r.attest) {'payload': a['payload'], 'sig': r.sigs[a['witness_did']]}
      ],
      'at': r.draft['at'],
    });
    rite = null;
    _deliver(out);
  }

  bool present(String compact, List<String> counterparties) => _try(() {
        partners.addAll(counterparties);
        _deliver(border.claims(compact, counterparties));
      });

  bool answerClaims(String compact, String presenter, {bool accepted = true}) =>
      _try(() => _deliver(border.verdicts(compact, presenter, accepted)));

  bool vouch(String compact, String entrant) => _try(() {
        partners.add(entrant);
        _deliver(border.sponsor(compact, entrant));
      });

  /// Seat examiners: `[{did, pub, node?}]`. A seat on another node also makes it a
  /// recipient of every delivery, so it can rebuild the seals it signs.
  bool seat(List<Map<String, dynamic>> seats) => _try(() {
        for (final s in seats) {
          final n = s['node'];
          if (n is String && n.length == 32) examinerNodes.add(n);
        }
        _relay(); // before _widen: the relay sends seals after their parts
        _widen();
        _deliver(border.examiners([
          for (final s in seats) {'did': s['did'], 'pub': s['pub']}
        ]));
      });

  /// Convene a seal: sign it here, and ask [signerNodes] (the other participants'
  /// governance nodes, and any examiners' nodes) to sign the same manifest.
  bool convene(String compact, List<String> participants, List<String> signerNodes) => _try(() {
        partners.addAll(participants.where((p) => p != border.polityDid));
        final d = border.sealDraft(compact, participants);
        final ask = SealAsk(compact, d['manifest'] as String, d['cid'] as String, d['kind'] as String, {});
        final mine = border.sealSign(ask.manifest);
        ask.sigs[border.selfDid] = mine['sig'] as String;
        seals[ask.cid] = ask;
        transport.ask(signerNodes, record: 'kc_seal', op: 'sign', cid: ask.cid, bytes: ask.manifest);
        _maybeLandSeal(ask);
        onChanged?.call();
      });

  void _maybeLandSeal(SealAsk ask) {
    if (ask.landed) return;
    try {
      final out = border.sealAssemble(ask.manifest, [
        for (final e in ask.sigs.entries) {'did': e.key, 'sig': e.value}
      ]);
      ask.landed = true;
      _queue('kc_seal', 'sealed', out['cid'] as String, out['sealed'] as String);
      _viewStale = true;
      onChanged?.call();
    } on Object {
      // Not every signature is in yet. The next one tries again.
    }
  }

  /// Draft an anathema (or its lifting) with [coReporters] (community DID ->
  /// governance node), sign it here, and ask them.
  bool report(String kind, String compact, Map<String, String> coReporters, String subject,
          {String? designation}) =>
      _try(() {
        final reporters = [border.polityDid, ...coReporters.keys];
        final d = border.conductDraft(kind, compact, reporters, subject, designation: designation);
        final payload = (d['payload'] as Map).cast<String, dynamic>();
        final mine = border.conductSign(compact, payload: payload);
        final ask = ConductAsk(compact, payload, d['cid'] as String, reporters,
            {mine['did'] as String: mine['sig'] as String});
        conducts[ask.cid] = ask;
        transport.ask(coReporters.values.toList(),
            record: 'kc_conduct', op: 'sign', cid: ask.cid, bytes: d['bytes'] as String);
        onChanged?.call();
      });

  void _maybeLandConduct(ConductAsk ask) {
    if (ask.landed || ask.sigs.length < ask.reporters.length) return;
    try {
      final out = border.conductAssemble(ask.payload, [
        for (final e in ask.sigs.entries) {'did': e.key, 'sig': e.value}
      ]);
      ask.landed = true;
      _deliver(out);
    } on Object catch (e) {
      lastError = '$e';
    }
  }

  // --- what arrives ----------------------------------------------------------

  /// An ask from another node. Returns whether it was a compact ask this engine
  /// answered (the people-facing ones are left to the co-signing list).
  bool onRequest({
    required String fromNode,
    required String record,
    required String op,
    required String cid,
    required String bytes,
  }) {
    switch ((record, op)) {
      case ('kc_record', 'deliver'):
        try {
          border.ingest(bytes);
          _relay();
          _viewStale = true;
          onChanged?.call();
          transport.answer(fromNode, cid: cid, signerDid: border.selfDid, sig: border.receiptSign(cid));
        } on Object catch (e) {
          lastError = 'a delivery from $fromNode was refused: $e';
        }
        return true;
      case ('kc_seal', 'sealed'):
        try {
          border.sealIngest(bytes);
          _relay();
          _viewStale = true;
          onChanged?.call();
          transport.answer(fromNode, cid: cid, signerDid: border.selfDid, sig: border.receiptSign(cid));
        } on Object catch (e) {
          // Not landable yet: a part has not arrived. The convener re-sends.
          lastError = 'a seal could not be rebuilt yet: $e';
        }
        return true;
      case ('kc_seal', 'sign'):
        try {
          final r = border.sealSign(bytes);
          transport.answer(fromNode, cid: cid, signerDid: border.selfDid, sig: r['sig'] as String);
        } on Object catch (e) {
          lastError = 'a seal ask was not signed: $e';
        }
        return true;
      case ('kc_conduct', 'sign'):
        // The ask does not say which compact; the cdylib checks this polity's
        // mandate for the record, so any compact we sit in that covers it will do.
        for (final compact in compactsWeSitIn) {
          try {
            final r = border.conductSign(compact, bytes: bytes);
            transport.answer(fromNode, cid: cid, signerDid: r['did'] as String, sig: r['sig'] as String);
            return true;
          } on Object catch (e) {
            lastError = 'a conduct ask was not signed: $e';
          }
        }
        return true;
    }
    return false;
  }

  /// The compacts this community sits in, as its own view says (set by the caller).
  List<String> compactsWeSitIn = const [];

  /// A signature that came back for one of our asks. Returns whether it was.
  bool onSignature({required String fromNode, required String cid, required String signerDid, required String sig}) {
    final o = _outbox[cid];
    if (o != null) {
      if (border.receiptVerify(cid, signerDid, sig)) {
        o.to[fromNode] = true;
        onChanged?.call();
      }
      return true;
    }
    final s = seals[cid];
    if (s != null) {
      s.sigs[signerDid] = sig;
      _maybeLandSeal(s);
      onChanged?.call();
      return true;
    }
    final c = conducts[cid];
    if (c != null) {
      c.sigs[signerDid] = sig;
      _maybeLandConduct(c);
      onChanged?.call();
      return true;
    }
    final r = rite;
    if (r != null && cid == _reciteCid(r.inductorDid) && signerDid == r.inductorDid) {
      r.recitationSig = sig;
      _try(_maybeSealRite);
      onChanged?.call();
      return true;
    }
    if (r != null) {
      for (final a in r.attest) {
        if (_attestCid(a) == cid && a['witness_did'] == signerDid) {
          r.sigs[signerDid] = sig;
          _try(_maybeSealRite);
          onChanged?.call();
          return true;
        }
      }
    }
    return false;
  }

  /// Re-send what is not acknowledged, a few at a time, and re-mint the view.
  void tick() {
    if (++_ticks % resendEveryTicks == 0) {
      var sent = 0;
      for (final o in _outbox.values) {
        final pending = [for (final e in o.to.entries) if (!e.value) e.key];
        if (pending.isEmpty) continue;
        transport.ask(pending, record: o.record, op: o.op, cid: o.cid, bytes: o.hex);
        if (++sent >= resendPerTick) break;
      }
      // New members (a fresh admission) get what they missed.
      _widen();
    }
    if (_viewStale && border.governs) {
      _viewStale = false;
      try {
        transport.publishView(border.viewSign(ownNode));
      } on Object catch (e) {
        lastError = 'the compact view could not be minted: $e';
      }
    }
  }

  String toJsonString() => jsonEncode({
        'replica': border.dump(),
        'outbox': [for (final o in _outbox.values) o.toJson()],
        'seals': [for (final s in seals.values) s.toJson()],
        'conducts': [for (final c in conducts.values) c.toJson()],
        if (rite != null) 'rite': rite!.toJson(),
        'examiner_nodes': examinerNodes.toList(),
        'partners': partners.toList(),
      });

  /// Restore the engine's own state (the replica is restored by the border).
  void restore(Map<String, dynamic> j) {
    for (final o in (j['outbox'] as List? ?? const [])) {
      final x = _Outgoing.fromJson((o as Map).cast<String, dynamic>());
      _outbox[x.cid] = x;
    }
    for (final s in (j['seals'] as List? ?? const [])) {
      final x = SealAsk.fromJson((s as Map).cast<String, dynamic>());
      seals[x.cid] = x;
    }
    for (final c in (j['conducts'] as List? ?? const [])) {
      final x = ConductAsk.fromJson((c as Map).cast<String, dynamic>());
      conducts[x.cid] = x;
    }
    final r = j['rite'];
    if (r is Map) rite = RiteAsk.fromJson(r.cast<String, dynamic>());
    examinerNodes.addAll([for (final n in (j['examiner_nodes'] as List? ?? const [])) n as String]);
    partners.addAll([for (final n in (j['partners'] as List? ?? const [])) n as String]);
  }
}

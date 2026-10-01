// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The kith-covenant border (SOCIAL_APP_PLAN Phase 5; Ethne D39, D40), over the
// ethne_agora cdylib's `ethne_kc_*` calls (native/ethne_ffi/src/kc.rs). A part of
// ethne_bindings.dart, because a compact act needs the charter log's handle.
//
// A community's governance node holds an [EthneKc] replica of every compact it is
// in. Everything it produces comes back as `{"deliveries":[{"kind","cid","hex"}]}`,
// the records to hand to the other members' replicas on the co-sign carrier.

part of 'ethne_bindings.dart';

typedef _KcPairC = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _KcPairDart = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);

/// A governance node's replica of its compacts.
class EthneKc {
  EthneKc._(this._ffi, this._handle);
  final EthneFfi _ffi;
  final Pointer<Void> _handle;
  bool _disposed = false;

  /// A fresh, empty replica.
  factory EthneKc.create(EthneFfi ffi) => EthneKc._(
      ffi, ffi._lib.lookupFunction<_ArchiveNewC, _ArchiveNewC>('ethne_kc_new')());

  /// A replica dumped by [dump]. Every entry re-verifies and re-authorizes, or
  /// this throws.
  factory EthneKc.load(EthneFfi ffi, String json) {
    final fn = ffi._lib.lookupFunction<_LoadJsonC, _LoadJsonDart>('ethne_kc_load_json');
    final s = json.toNativeUtf8();
    try {
      final h = fn(s);
      if (h == nullptr) throw EthneException(ffi._err());
      return EthneKc._(ffi, h);
    } finally {
      calloc.free(s);
    }
  }

  void _check() {
    if (_disposed) throw EthneException('replica used after dispose');
  }

  String _kc(String name, Map<String, dynamic> spec) {
    _check();
    final fn = _ffi._lib.lookupFunction<_StateC, _StateDart>(name);
    final s = jsonEncode(spec).toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (fn(_handle, s, out) != 0) throw EthneException(_ffi._err());
      return _ffi._takeString(out);
    } finally {
      calloc.free(s);
      calloc.free(out);
    }
  }

  String _pair(String name, EthneArchive charter, Map<String, dynamic> spec) {
    _check();
    charter._check();
    final fn = _ffi._lib.lookupFunction<_KcPairC, _KcPairDart>(name);
    final s = jsonEncode(spec).toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (fn(charter._handle, _handle, s, out) != 0) throw EthneException(_ffi._err());
      return _ffi._takeString(out);
    } finally {
      calloc.free(s);
      calloc.free(out);
    }
  }

  Map<String, dynamic> _json(String s) => jsonDecode(s) as Map<String, dynamic>;

  String dump() {
    _check();
    final fn = _ffi._lib.lookupFunction<_HandleOutC, _HandleOutDart>('ethne_kc_dump_json');
    final out = calloc<Pointer<Utf8>>();
    try {
      if (fn(_handle, out) != 0) throw EthneException(_ffi._err());
      return _ffi._takeString(out);
    } finally {
      calloc.free(out);
    }
  }

  /// Whether the replica verifies and authorizes under Agora's fixed KC parameters.
  bool verify() {
    _check();
    return _ffi._lib.lookupFunction<_VerifyC, _VerifyDart>('ethne_kc_verify')(_handle) == 0;
  }

  /// Publish the polity's identity and envoy delegation at KC's border.
  Map<String, dynamic> border(EthneArchive charter,
          {required String polityDid, required Map<String, dynamic> rootPriv, required String envoyDid}) =>
      _json(_pair('ethne_kc_border', charter,
          {'polity_did': polityDid, 'root_priv': rootPriv, 'envoy_did': envoyDid}));

  /// Draft the polity's KC rite: the Reciter delegation and witness registry are
  /// published; the result carries the recitation to sign and each witness's
  /// attestation bytes.
  Map<String, dynamic> riteDraft(EthneArchive charter,
          {required String polityDid, required Map<String, dynamic> rootPriv, required String inductorDid}) =>
      _json(_pair('ethne_kc_rite_draft', charter,
          {'polity_did': polityDid, 'root_priv': rootPriv, 'inductor_did': inductorDid}));

  Map<String, dynamic> riteSeal(Map<String, dynamic> spec) => _json(_kc('ethne_kc_rite_seal', spec));

  Map<String, dynamic> claims(EthneArchive charter,
          {required String polityDid,
          required String compact,
          required List<String> counterparties,
          required Map<String, dynamic> envoyPriv}) =>
      _json(_pair('ethne_kc_claims', charter, {
        'polity_did': polityDid,
        'compact': compact,
        'counterparties': counterparties,
        'envoy_priv': envoyPriv,
      }));

  Map<String, dynamic> verdicts(EthneArchive charter,
          {required String polityDid,
          required String compact,
          required String presenter,
          required bool accepted,
          String? rationale,
          required Map<String, dynamic> envoyPriv}) =>
      _json(_pair('ethne_kc_verdicts', charter, {
        'polity_did': polityDid,
        'compact': compact,
        'presenter': presenter,
        'accepted': accepted,
        if (rationale != null) 'rationale': rationale,
        'envoy_priv': envoyPriv,
      }));

  Map<String, dynamic> sponsor(EthneArchive charter,
          {required String polityDid,
          required String compact,
          required String entrant,
          required Map<String, dynamic> envoyPriv}) =>
      _json(_pair('ethne_kc_sponsor', charter, {
        'polity_did': polityDid,
        'compact': compact,
        'entrant': entrant,
        'envoy_priv': envoyPriv,
      }));

  /// Seat examiners (`[{did, pub}]`) for [days] (at most 182). Root-signed.
  Map<String, dynamic> examiners(
          {required String polityDid,
          required Map<String, dynamic> rootPriv,
          required List<Map<String, dynamic>> seats,
          int days = 180}) =>
      _json(_kc('ethne_kc_examiners',
          {'polity_did': polityDid, 'root_priv': rootPriv, 'seats': seats, 'days': days}));

  /// A seal manifest over what the replica holds: `{manifest, kind, cid, sitting}`.
  Map<String, dynamic> sealDraft({required String compact, required List<String> participants}) =>
      _json(_kc('ethne_kc_seal_draft', {'compact': compact, 'participants': participants}));

  /// Rebuild the seal [manifest] names, check this polity's mandate, and sign:
  /// `{cid, kind, sig}`.
  Map<String, dynamic> sealSign(EthneArchive charter,
          {required String manifest,
          required String polityDid,
          required String signerDid,
          required Map<String, dynamic> signerPriv}) =>
      _json(_pair('ethne_kc_seal_sign', charter, {
        'manifest': manifest,
        'polity_did': polityDid,
        'signer_did': signerDid,
        'signer_priv': signerPriv,
      }));

  /// Rebuild, attach [signatures] (`[{did, sig}]`) and land a seal: `{cid, sealed}`,
  /// where `sealed` is the note to send every member. Throws while the signatures
  /// collected so far do not authorize it; nothing is held meanwhile.
  Map<String, dynamic> sealAssemble(String manifest, List<Map<String, dynamic>> signatures) =>
      _json(_kc('ethne_kc_seal_assemble', {'manifest': manifest, 'signatures': signatures}));

  /// Land the seal a convener's sealed note names, rebuilt from this replica.
  Map<String, dynamic> sealIngest(String sealedHex) {
    _check();
    final fn = _ffi._lib.lookupFunction<_StateC, _StateDart>('ethne_kc_seal_ingest');
    final s = sealedHex.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (fn(_handle, s, out) != 0) throw EthneException(_ffi._err());
      return _json(_ffi._takeString(out));
    } finally {
      calloc.free(s);
      calloc.free(out);
    }
  }

  /// A reporter's signature on a conduct record, given as [payload] or as the
  /// canonical [bytes] a co-reporter was handed: `{did, sig}`.
  Map<String, dynamic> conductSign(EthneArchive charter,
          {required String polityDid,
          required String compact,
          Map<String, dynamic>? payload,
          String? bytes,
          required Map<String, dynamic> envoyPriv}) =>
      _json(_pair('ethne_kc_conduct_sign', charter, {
        'polity_did': polityDid,
        'compact': compact,
        if (payload != null) 'payload': payload,
        if (bytes != null) 'bytes': bytes,
        'envoy_priv': envoyPriv,
      }));

  Map<String, dynamic> conductAssemble(Map<String, dynamic> payload, List<Map<String, dynamic>> signatures) =>
      _json(_kc('ethne_kc_conduct_assemble', {'payload': payload, 'signatures': signatures}));

  /// Everything the replica holds as it travels, seals last:
  /// `[{record, op, kind, cid, hex}]` (records as `kc_record/deliver`, seals as
  /// the `kc_seal/sealed` note they came in).
  List<Map<String, dynamic>> deliveries() => [
        for (final d in (_json(_kc('ethne_kc_deliveries', const {}))['deliveries'] as List))
          (d as Map).cast<String, dynamic>(),
      ];

  /// Take one delivery in: `{cid, kind, status: "landed"|"held", held}`. Throws
  /// for a record that can never land.
  Map<String, dynamic> ingest(String hex) {
    _check();
    final fn = _ffi._lib.lookupFunction<_StateC, _StateDart>('ethne_kc_ingest');
    // The spec is the delivery hex itself, not JSON.
    final s = hex.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (fn(_handle, s, out) != 0) throw EthneException(_ffi._err());
      return _json(_ffi._takeString(out));
    } finally {
      calloc.free(s);
      calloc.free(out);
    }
  }

  /// KC's reading of [communityDid] in this replica, now.
  String standing(String communityDid) {
    _check();
    final fn = _ffi._lib.lookupFunction<_StateC, _StateDart>('ethne_kc_standing');
    final s = communityDid.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (fn(_handle, s, out) != 0) throw EthneException(_ffi._err());
      return _json(_ffi._takeString(out))['standing'] as String;
    } finally {
      calloc.free(s);
      calloc.free(out);
    }
  }

  /// The community's compact view, root-signed, as the bundle its carrier holds.
  String viewSign({required String polityDid, required Map<String, dynamic> rootPriv, required String node}) =>
      _kc('ethne_kc_view_sign', {'polity_did': polityDid, 'root_priv': rootPriv, 'node': node});

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ffi._lib.lookupFunction<_ArchiveFreeC, _ArchiveFreeDart>('ethne_kc_free')(_handle);
  }
}

/// The stateless kith-covenant calls.
extension EthneKcCalls on EthneFfi {
  /// Draft an anathema or its lifting for the reporters to co-sign:
  /// `{payload, bytes, cid}`.
  Map<String, dynamic> kcConductDraft(EthneArchive charter, Map<String, dynamic> spec) {
    charter._check();
    final fn = _lib.lookupFunction<_StateC, _StateDart>('ethne_kc_conduct_draft');
    final s = jsonEncode(spec).toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (fn(charter._handle, s, out) != 0) throw EthneException(_err());
      return jsonDecode(_takeString(out)) as Map<String, dynamic>;
    } finally {
      calloc.free(s);
      calloc.free(out);
    }
  }

  /// A receipt for delivery [cid], signed with [priv] (domain-separated, so it
  /// can never pass as a signature over the record).
  String kcReceiptSign(String cid, Map<String, dynamic> priv) => _specOut(
      _lib.lookupFunction<_SpecOutC, _SpecOutDart>('ethne_kc_receipt_sign'),
      jsonEncode({'cid': cid, 'priv': priv}));

  bool kcReceiptVerify({required String cid, required String did, required String sig}) {
    final fn = _lib.lookupFunction<_StrC, _StrDart>('ethne_kc_receipt_verify');
    final s = jsonEncode({'cid': cid, 'did': did, 'sig': sig}).toNativeUtf8();
    try {
      return fn(s) == 0;
    } finally {
      calloc.free(s);
    }
  }

  /// Verify a compact view bundle: `{community_did, node, seq, as_of, compacts,
  /// standings: {did: word}}`, or null when it does not verify.
  Map<String, dynamic>? compactViewVerify(String bundle) {
    try {
      return jsonDecode(_specOut(
              _lib.lookupFunction<_SpecOutC, _SpecOutDart>('ethne_compact_view_verify'), bundle))
          as Map<String, dynamic>;
    } on EthneException {
      return null;
    }
  }

  /// What a policy does to a post made in [postCommunity], by its standing in the
  /// publisher's verified [view] (D39): `{standing, action}`.
  Map<String, dynamic> compactStandingVerdict(
          {required Map<String, dynamic> policy,
          required Map<String, dynamic> view,
          required String postCommunity}) =>
      jsonDecode(_specOut(
          _lib.lookupFunction<_SpecOutC, _SpecOutDart>('ethne_compact_standing_verdict'),
          jsonEncode({'policy': policy, 'view': view, 'post_community': postCommunity})))
          as Map<String, dynamic>;
}

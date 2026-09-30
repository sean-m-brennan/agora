// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Dart FFI over the ethne_agora cdylib (native/ethne_ffi) — the C-ABI bridge to
// Ethne's Rust charter engine, so Agora can found and read an Ethne polity (a
// "business", SOCIAL_APP_PLAN.md §2.2 / Phase 3) with no Python. Mirrors the
// shape of at_events_bindings.dart: a loader, raw lookups, and small typed
// wrappers. Everything crosses as JSON strings; the live charter log is an
// opaque handle held by [EthneArchive].

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// --- Raw C signatures --------------------------------------------------------

typedef _LastErrorC = Pointer<Utf8> Function();
typedef _StringFreeC = Void Function(Pointer<Utf8>);
typedef _StringFreeDart = void Function(Pointer<Utf8>);

typedef _ArchiveNewC = Pointer<Void> Function();
typedef _ArchiveFreeC = Void Function(Pointer<Void>);
typedef _ArchiveFreeDart = void Function(Pointer<Void>);

typedef _OutStrC = Int32 Function(Pointer<Pointer<Utf8>>);
typedef _OutStrDart = int Function(Pointer<Pointer<Utf8>>);

typedef _HandleSpecC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _HandleSpecDart = int Function(Pointer<Void>, Pointer<Utf8>);

typedef _HandleOutC = Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _HandleOutDart = int Function(Pointer<Void>, Pointer<Pointer<Utf8>>);

/// A `(spec-string, out-string)` call with no archive handle — the detached
/// signer's half, which needs only the bytes and its own key.
typedef _SignC = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _SignDart = int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _StateC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _StateDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);

typedef _VerifyC = Int32 Function(Pointer<Void>);
typedef _VerifyDart = int Function(Pointer<Void>);

typedef _LoadJsonC = Pointer<Void> Function(Pointer<Utf8>);
typedef _LoadJsonDart = Pointer<Void> Function(Pointer<Utf8>);

// P3.1: business page sign (no handle: spec in, string out) and verify-bundle
// (no handle: one string in).
typedef _SpecOutC = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _SpecOutDart = int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);

typedef _StrC = Int32 Function(Pointer<Utf8>);
typedef _StrDart = int Function(Pointer<Utf8>);

/// Thrown when an ethne_agora call fails; [message] is `ethne_last_error()`.
class EthneException implements Exception {
  EthneException(this.message);
  final String message;
  @override
  String toString() => 'EthneException: $message';
}

/// A generated polity/member identity. [priv] and [pub] are opaque JSON blobs
/// (serialized Ed25519 keys) the caller stores; [priv] is passed back to sign.
class EthneKeypair {
  EthneKeypair(this.did, this.priv, this.pub);
  final String did;
  final Map<String, dynamic> priv;
  final Map<String, dynamic> pub;
}

/// Loads and binds the ethne_agora cdylib. Path resolution mirrors the AT shim:
/// `$AGORA_ETHNE_PATH`, else a conventional `native/build/libethne_agora.so`.
class EthneFfi {
  EthneFfi._(DynamicLibrary lib)
      : _lastError =
            lib.lookupFunction<_LastErrorC, _LastErrorC>('ethne_last_error'),
        _stringFree = lib
            .lookupFunction<_StringFreeC, _StringFreeDart>('ethne_string_free'),
        _archiveNew =
            lib.lookupFunction<_ArchiveNewC, _ArchiveNewC>('ethne_archive_new'),
        _archiveFree = lib
            .lookupFunction<_ArchiveFreeC, _ArchiveFreeDart>('ethne_archive_free'),
        _keypairGenerate = lib
            .lookupFunction<_OutStrC, _OutStrDart>('ethne_keypair_generate'),
        _foundPolity = lib
            .lookupFunction<_HandleSpecC, _HandleSpecDart>('ethne_found_polity'),
        _admitMember = lib
            .lookupFunction<_HandleSpecC, _HandleSpecDart>('ethne_admit_member'),
        // P3.3 S3 — detached two-phase signing (D15): no private key leaves
        // its owner's node.
        _pending = lib.lookupFunction<_StateC, _StateDart>('ethne_pending'),
        _signDetached =
            lib.lookupFunction<_SignC, _SignDart>('ethne_sign_detached'),
        _assemble = lib
            .lookupFunction<_HandleSpecC, _HandleSpecDart>('ethne_assemble'),
        // P3.3 S5 — the signer's node derives the wording itself. No handle and
        // no polity: what an act means is a property of its bytes.
        _describe =
            lib.lookupFunction<_SpecOutC, _SpecOutDart>('ethne_describe'),
        // P3.3 S2 — leaving the roll. Departure and expulsion are deliberately
        // not symmetric acts.
        _departMember = lib
            .lookupFunction<_HandleSpecC, _HandleSpecDart>('ethne_depart_member'),
        _expelMember = lib
            .lookupFunction<_HandleSpecC, _HandleSpecDart>('ethne_expel_member'),
        // P3.3 S4 — guardianship: who a machine answers to (D15). An edge that
        // is claimed must carry what the substrate showed, or say outright that
        // nothing did.
        _observe = lib.lookupFunction<_StateC, _StateDart>('ethne_observe'),
        _designateDerived = lib.lookupFunction<_HandleSpecC, _HandleSpecDart>(
            'ethne_designate_derived'),
        _rotateGuardian = lib.lookupFunction<_HandleSpecC, _HandleSpecDart>(
            'ethne_rotate_guardian'),
        _releaseGuardian = lib.lookupFunction<_HandleSpecC, _HandleSpecDart>(
            'ethne_release_guardian'),
        _guardianState =
            lib.lookupFunction<_StateC, _StateDart>('ethne_guardian_state'),
        // P3.3 S1 — the induction rite (D29). Admission puts somebody on the
        // roll; induction is how they acquire the substrate, and only
        // ratifiers-or-inducted members carry deliberative weight.
        _reciteMovement = lib
            .lookupFunction<_StateC, _StateDart>('ethne_recite_movement'),
        _inductMember = lib
            .lookupFunction<_HandleSpecC, _HandleSpecDart>('ethne_induct_member'),
        _affirmationState = lib
            .lookupFunction<_StateC, _StateDart>('ethne_affirmation_state'),
        _charterState =
            lib.lookupFunction<_StateC, _StateDart>('ethne_charter_state'),
        _verify = lib.lookupFunction<_VerifyC, _VerifyDart>('ethne_verify'),
        _dumpJson = lib
            .lookupFunction<_HandleOutC, _HandleOutDart>('ethne_archive_dump_json'),
        _loadJson = lib
            .lookupFunction<_LoadJsonC, _LoadJsonDart>('ethne_archive_load_json'),
        // P3.1 — envoy office + business-page border artifact (box 2).
        _authorizeEnvoy = lib
            .lookupFunction<_HandleSpecC, _HandleSpecDart>('ethne_authorize_envoy'),
        _envoyState =
            lib.lookupFunction<_StateC, _StateDart>('ethne_envoy_state'),
        _communityIdentity = lib
            .lookupFunction<_StateC, _StateDart>('ethne_community_identity'),
        _envoyDelegation = lib
            .lookupFunction<_StateC, _StateDart>('ethne_envoy_delegation'),
        _pageSign = lib
            .lookupFunction<_SpecOutC, _SpecOutDart>('ethne_business_page_sign'),
        _verifyBundle = lib.lookupFunction<_StrC, _StrDart>(
            'ethne_business_page_verify_bundle'),
        _verifyFull = lib.lookupFunction<_HandleSpecC, _HandleSpecDart>(
            'ethne_business_page_verify_full'),
        // P3.4 — the business-post artifact (box 5).
        _postSign = lib
            .lookupFunction<_SpecOutC, _SpecOutDart>('ethne_business_post_sign'),
        _verifyPostBundle = lib.lookupFunction<_StrC, _StrDart>(
            'ethne_business_post_verify_bundle'),
        _verifyPostFull = lib.lookupFunction<_HandleSpecC, _HandleSpecDart>(
            'ethne_business_post_verify_full'),
        // P3.3 S9 — the member-roll border artifact (D26).
        _rollSign =
            lib.lookupFunction<_StateC, _StateDart>('ethne_member_roll_sign'),
        _rollVerify =
            lib.lookupFunction<_StrC, _StrDart>('ethne_member_roll_verify'),
        _rollVerifyFull = lib.lookupFunction<_HandleSpecC, _HandleSpecDart>(
            'ethne_member_roll_verify_full'),
        // Phase 4 — per-community content policy (Ethne D37). The roll sets the
        // policy; a Moderator labels alone; the verdict is computed here so the
        // app and the live cohort run the same code.
        _amendContentPolicy = lib.lookupFunction<_HandleSpecC, _HandleSpecDart>(
            'ethne_amend_content_policy'),
        _conferOffice = lib
            .lookupFunction<_HandleSpecC, _HandleSpecDart>('ethne_confer_office'),
        _revokeOffice = lib
            .lookupFunction<_HandleSpecC, _HandleSpecDart>('ethne_revoke_office'),
        _declareRelayEndpoint = lib.lookupFunction<_HandleSpecC, _HandleSpecDart>(
            'ethne_declare_relay_endpoint'),
        _contentPolicyState = lib
            .lookupFunction<_StateC, _StateDart>('ethne_content_policy_state'),
        _contentPolicySign = lib
            .lookupFunction<_StateC, _StateDart>('ethne_content_policy_sign'),
        _contentPolicyVerify = lib.lookupFunction<_SpecOutC, _SpecOutDart>(
            'ethne_content_policy_verify'),
        _postLabelSign =
            lib.lookupFunction<_SpecOutC, _SpecOutDart>('ethne_post_label_sign'),
        _postLabelVerify = lib
            .lookupFunction<_SpecOutC, _SpecOutDart>('ethne_post_label_verify'),
        _contentPolicyVerdict = lib.lookupFunction<_SpecOutC, _SpecOutDart>(
            'ethne_content_policy_verdict');

  final _LastErrorC _lastError;
  final _StringFreeDart _stringFree;
  final _ArchiveNewC _archiveNew;
  final _ArchiveFreeDart _archiveFree;
  final _OutStrDart _keypairGenerate;
  final _HandleSpecDart _foundPolity;
  final _HandleSpecDart _admitMember;
  final _StateDart _pending;
  final _SignDart _signDetached;
  final _HandleSpecDart _assemble;
  final _SpecOutDart _describe;
  final _HandleSpecDart _departMember;
  final _HandleSpecDart _expelMember;
  final _StateDart _observe;
  final _HandleSpecDart _designateDerived;
  final _HandleSpecDart _rotateGuardian;
  final _HandleSpecDart _releaseGuardian;
  final _StateDart _guardianState;
  final _StateDart _reciteMovement;
  final _HandleSpecDart _inductMember;
  final _StateDart _affirmationState;
  final _StateDart _charterState;
  final _VerifyDart _verify;
  final _HandleOutDart _dumpJson;
  final _LoadJsonDart _loadJson;
  final _HandleSpecDart _authorizeEnvoy;
  final _StateDart _envoyState;
  final _StateDart _communityIdentity;
  final _StateDart _envoyDelegation;
  final _SpecOutDart _pageSign;
  final _StrDart _verifyBundle;
  final _HandleSpecDart _verifyFull;
  final _SpecOutDart _postSign;
  final _StrDart _verifyPostBundle;
  final _HandleSpecDart _verifyPostFull;
  final _StateDart _rollSign;
  final _StrDart _rollVerify;
  final _HandleSpecDart _rollVerifyFull;
  final _HandleSpecDart _amendContentPolicy;
  final _HandleSpecDart _conferOffice;
  final _HandleSpecDart _revokeOffice;
  final _HandleSpecDart _declareRelayEndpoint;
  final _StateDart _contentPolicyState;
  final _StateDart _contentPolicySign;
  final _SpecOutDart _contentPolicyVerify;
  final _SpecOutDart _postLabelSign;
  final _SpecOutDart _postLabelVerify;
  final _SpecOutDart _contentPolicyVerdict;

  /// A `(spec-string, out-string)` call: encode [spec], run [fn], and return the
  /// JSON string it emitted.
  String _specOut(_SpecOutDart fn, String spec) {
    final s = spec.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (fn(s, out) != 0) throw EthneException(_err());
      return _takeString(out);
    } finally {
      calloc.free(s);
      calloc.free(out);
    }
  }

  /// Resolve the library path, or null if not wired (caller then skips).
  static String? resolveLibraryPath() {
    final env = Platform.environment['AGORA_ETHNE_PATH'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    const conventional = 'native/build/libethne_agora.so';
    if (File(conventional).existsSync()) return conventional;
    return null;
  }

  /// Open the cdylib. Throws if [path] (or the resolved default) is missing.
  factory EthneFfi.open([String? path]) {
    final p = path ?? resolveLibraryPath();
    if (p == null) {
      throw EthneException('ethne_agora library not found '
          '(set AGORA_ETHNE_PATH or build native/build/libethne_agora.so)');
    }
    return EthneFfi._(DynamicLibrary.open(p));
  }

  String _err() => _lastError().toDartString();

  /// Read a C string an out-param call produced, then free it.
  String _takeString(Pointer<Pointer<Utf8>> out) {
    final s = out.value.toDartString();
    _stringFree(out.value);
    return s;
  }

  /// Generate a fresh Ed25519 identity.
  EthneKeypair generateKeypair() {
    final out = calloc<Pointer<Utf8>>();
    try {
      final rc = _keypairGenerate(out);
      if (rc != 0) throw EthneException(_err());
      final m = jsonDecode(_takeString(out)) as Map<String, dynamic>;
      return EthneKeypair(m['did'] as String,
          m['priv'] as Map<String, dynamic>, m['pub'] as Map<String, dynamic>);
    } finally {
      calloc.free(out);
    }
  }

  /// A fresh, empty polity charter log.
  EthneArchive newArchive() => EthneArchive._(this, _archiveNew());

  /// Sign detached [bytesHex] with [priv] — the signer's own half of a
  /// two-phase exchange, run in the signer's own process on their own node.
  ///
  /// Takes no archive and no polity: a signer needs the exported bytes and
  /// their key, nothing else. That is precisely why the key never has to move.
  /// Show the exchange's `description` to whoever is signing — signing opaque
  /// bytes is a habit worth not teaching.
  String signDetached({
    required Map<String, dynamic> priv,
    required String bytesHex,
  }) {
    final spec = jsonEncode({'priv': priv, 'bytes': bytesHex}).toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_signDetached(spec, out) != 0) throw EthneException(_err());
      return _takeString(out);
    } finally {
      calloc.free(spec);
      calloc.free(out);
    }
  }

  /// Say what the canonical [bytesHex] of a co-signature exchange actually
  /// commits to: the act, the parties, the evidence grade, the recomputed cid
  /// and the wording. [record] is `'membership'` (the default) or `'guardian'`;
  /// bytes that do not deserialize as that class are refused.
  ///
  /// Returns `{record, op, polity_did, member_did, deciders, …, cid, description}`.
  ///
  /// Like [signDetached] this takes no archive and no polity, and that is the
  /// point: the description is DERIVED HERE, on the node about to sign, from the
  /// same bytes the signature will cover. No description crosses the wire (P3.3
  /// S5), because a node that could choose both what you sign and what you are
  /// told you are signing could put a friendly sentence over hostile bytes and
  /// collect a real signature on the end of it. Recompute, never quote.
  Map<String, dynamic> describe({
    String? record,
    required String bytesHex,
  }) {
    final spec = jsonEncode({
      if (record != null) 'record': record,
      'bytes': bytesHex,
    }).toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_describe(spec, out) != 0) throw EthneException(_err());
      return jsonDecode(_takeString(out)) as Map<String, dynamic>;
    } finally {
      calloc.free(spec);
      calloc.free(out);
    }
  }

  /// Verify a self-contained member roll (a `Signed<MemberRoll>`): signed by the
  /// polity it names, and well-formed. Needs no charter log — a roll's signer IS
  /// the community, whose key resolves out of its own DID, so unlike a business
  /// page there is no delegation to carry and nothing to bundle it with.
  ///
  /// THIS PROVES THE PUBLISHER, NOT THE ROLL. A roll is the polity speaking about
  /// itself; this says the polity is the one saying it, and cannot say whether
  /// what it says is true. It is exactly the reach a compact tier has. To audit
  /// the claim you need the log — see [EthneArchive.verifyMemberRollFull].
  bool verifyMemberRoll(String rollJson) {
    final s = rollJson.toNativeUtf8();
    try {
      return _rollVerify(s) == 0;
    } finally {
      calloc.free(s);
    }
  }

  /// Reload a charter log from the JSON [envelope] dumped by [EthneArchive.dumpJson].
  EthneArchive loadArchive(String envelope) {
    final s = envelope.toNativeUtf8();
    try {
      final h = _loadJson(s);
      if (h == nullptr) throw EthneException(_err());
      return EthneArchive._(this, h);
    } finally {
      calloc.free(s);
    }
  }

  /// Sign a business page as [envoy], returning the `Signed<BusinessPage>` JSON
  /// (the `page` half of a self-contained bundle). Fields are bounded native-
  /// side; `seq` versions successive pages. Needs no charter log — only the
  /// envoy's key — so it lives on [EthneFfi], not [EthneArchive].
  ///
  /// [locality] is a coarse GEOHASH BUCKET (≤12 chars, the same form and
  /// precision as a peer's opt-in position), not free text: it is the page's
  /// geographic anchor, and "businesses near me" (P3.2) ranks distance from it
  /// via [geohashDistanceKm]. A business address is public, so unlike a person's
  /// position this is advertised openly — but it stays a BUCKET, never
  /// coordinates. Empty means the page is unplaced and cannot rank by distance.
  String signBusinessPage({
    required String polityDid,
    required EthneKeypair envoy,
    String name = '',
    String category = '',
    String description = '',
    String locality = '',
    String contact = '',
    int seq = 0,
  }) {
    final spec = jsonEncode({
      'page': {
        'polity_did': polityDid,
        'name': name,
        'category': category,
        'description': description,
        'locality': locality,
        'contact': contact,
        'seq': seq,
      },
      'envoy_did': envoy.did,
      'envoy_priv': envoy.priv,
    }).toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_pageSign(spec, out) != 0) throw EthneException(_err());
      return _takeString(out);
    } finally {
      calloc.free(spec);
      calloc.free(out);
    }
  }

  /// Verify a SELF-CONTAINED business-page bundle `{"page","delegation"}` with
  /// no charter log: proves polity-root → envoy → page. True if authentic; on
  /// false, the reason is in [EthneArchive.lastError]/`ethne_last_error`.
  bool verifyBusinessPageBundle(String bundleJson) {
    final s = bundleJson.toNativeUtf8();
    try {
      return _verifyBundle(s) == 0;
    } finally {
      calloc.free(s);
    }
  }

  /// Sign a business POST as [envoy], returning the `Signed<BusinessPost>` JSON
  /// (the `post` half of a self-contained bundle). Needs no charter log — only
  /// the envoy's key — so it lives on [EthneFfi], not [EthneArchive].
  ///
  /// A page is what the business IS; a post is what it SAYS. [seq] ORDERS a
  /// business's posts, it does not version them: a post is never superseded,
  /// which is why it is a payload of its own rather than a field on the page.
  ///
  /// [body] is clamped native-side to 512 chars, a bound chosen so the worst
  /// case bundle still fits the wire cap the C core enforces. An empty body, or
  /// one carrying control characters other than newline and tab, is REFUSED —
  /// the first would put the envoy's authority behind nothing, the second would
  /// make the wire size a function of the input.
  String signBusinessPost({
    required String polityDid,
    required EthneKeypair envoy,
    required String body,
    int seq = 0,
  }) {
    final spec = jsonEncode({
      'post': {'polity_did': polityDid, 'body': body, 'seq': seq},
      'envoy_did': envoy.did,
      'envoy_priv': envoy.priv,
    }).toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_postSign(spec, out) != 0) throw EthneException(_err());
      return _takeString(out);
    } finally {
      calloc.free(spec);
      calloc.free(out);
    }
  }

  /// Verify a SELF-CONTAINED business-post bundle `{"post","delegation"}` with
  /// no charter log: proves polity-root → envoy → post. THIS IS THE READER'S
  /// VERIFIER — someone who holds the business's page holds no charter archive
  /// — and nothing may be rendered as the business's words until it returns
  /// true. On false, the reason is in [lastError]/`ethne_last_error`.
  bool verifyBusinessPostBundle(String bundleJson) {
    final s = bundleJson.toNativeUtf8();
    try {
      return _verifyPostBundle(s) == 0;
    } finally {
      calloc.free(s);
    }
  }

  /// Verify a community's policy artifact (a `Signed<CommunityPolicy>`) and say
  /// what it holds: `{community_did, seq, policy, moderators}`. Needs no log: the
  /// community's DID is its root key. Null when it does not verify — the reason
  /// is in [lastError]. Keep the highest `seq` per community; a newer policy
  /// replaces an older one whole (Ethne D37).
  Map<String, dynamic>? verifyContentPolicy(String policyJson) {
    try {
      return jsonDecode(_specOut(_contentPolicyVerify, policyJson))
          as Map<String, dynamic>;
    } on EthneException {
      return null;
    }
  }

  /// Label post [postId] in [communityDid] as [moderator], returning the
  /// `Signed<PostLabel>` JSON. An empty [labels] retracts this moderator's
  /// earlier labels on the post; [seq] must exceed their last label on it.
  /// Whether the label counts is each reader's call, against the policy they
  /// hold: it counts only while that policy lists [moderator].
  String signPostLabel({
    required String communityDid,
    required String postId,
    required List<String> labels,
    required int seq,
    required EthneKeypair moderator,
  }) =>
      _specOut(
          _postLabelSign,
          jsonEncode({
            'community_did': communityDid,
            'post_id': postId,
            'labels': labels,
            'seq': seq,
            'moderator': {'did': moderator.did, 'priv': moderator.priv},
          }));

  /// Verify [labelJson] against [policyJson]: `{moderator_did, community_did,
  /// post_id, labels, seq, ts}`, or null when it does not verify or its signer
  /// is not a moderator the policy lists.
  Map<String, dynamic>? verifyPostLabel({
    required String labelJson,
    required String policyJson,
  }) {
    try {
      return jsonDecode(_specOut(_postLabelVerify,
              jsonEncode({'label': labelJson, 'policy': policyJson})))
          as Map<String, dynamic>;
    } on EthneException {
      return null;
    }
  }

  /// How this reader shows one post made in a community it follows:
  /// `{community_did, seq, action: show|warn|hide, reasons, tags,
  /// labels_refused}`. Each reason is `{code, …}` with code `operator_unbound`,
  /// `below_min_tier`, `over_daily_cap` or `label` (with `label`, `action`,
  /// `by`). [labels] are the moderator labels held for the post, as received;
  /// ones that do not verify are skipped and counted. The author measures are
  /// this reader's own: its tier for the author, whether the author is
  /// operator-bound, and this post's 1-based place among the author's posts in
  /// the community today (UTC).
  Map<String, dynamic> contentPolicyVerdict({
    required String policyJson,
    required String postId,
    List<String> authorLabels = const [],
    List<String> labels = const [],
    required int authorTier,
    required bool authorOperatorBound,
    required int authorPostIndexToday,
  }) =>
      jsonDecode(_specOut(
          _contentPolicyVerdict,
          jsonEncode({
            'policy': policyJson,
            'post_id': postId,
            'author_labels': authorLabels,
            'labels': labels,
            'author_tier': authorTier,
            'author_operator_bound': authorOperatorBound,
            'author_post_index_today': authorPostIndexToday,
          }))) as Map<String, dynamic>;

  /// Last native error message (shared across all ethne_agora calls).
  String lastError() => _err();
}

/// An opaque Ethne charter log (one polity's append-only record). Call
/// [dispose] when done to free the native handle.
class EthneArchive {
  EthneArchive._(this._ffi, this._handle);
  final EthneFfi _ffi;
  final Pointer<Void> _handle;
  bool _disposed = false;

  void _check() {
    if (_disposed) throw EthneException('archive used after dispose');
  }

  void _callSpec(_HandleSpecDart fn, Map<String, dynamic> spec) {
    _check();
    final s = jsonEncode(spec).toNativeUtf8();
    try {
      if (fn(_handle, s) != 0) throw EthneException(_ffi._err());
    } finally {
      calloc.free(s);
    }
  }

  /// A `(handle, spec-string, out-string)` call: encode [spec], run [fn], and
  /// return the JSON string it emitted.
  String _callSpecOut(_StateDart fn, Map<String, dynamic> spec) {
    _check();
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

  /// Found the polity: ratify + append the genesis charter. [ratifiers] must be
  /// a majority of [memberDids]; [name]/[statement] must be non-empty.
  void foundPolity({
    required String polityDid,
    required String name,
    required String statement,
    required List<String> memberDids,
    required List<EthneKeypair> ratifiers,
  }) {
    _callSpec(_ffi._foundPolity, {
      'polity_did': polityDid,
      'name': name,
      'statement': statement,
      'members': memberDids,
      'ratifiers': ratifiers.map((r) => {'did': r.did, 'priv': r.priv}).toList(),
    });
  }

  /// Admit [memberDid]. [deciders] are a majority of the current roll; [joiner]
  /// co-signs (consent).
  void admitMember({
    required String polityDid,
    required String memberDid,
    String rationale = '',
    required List<EthneKeypair> deciders,
    required EthneKeypair joiner,
  }) {
    _callSpec(_ffi._admitMember, {
      'polity_did': polityDid,
      'member_did': memberDid,
      'rationale': rationale,
      'deciders': deciders.map((d) => {'did': d.did, 'priv': d.priv}).toList(),
      'joiner': {'did': joiner.did, 'priv': joiner.priv},
    });
  }

  /// Begin a detached exchange for a roll act that needs co-signatures.
  ///
  /// [op] is `'admit'` or `'expel'`; a voluntary departure is self-signed by one
  /// person and needs no exchange. [deciderDids] are DIDs **only** — the whole
  /// point is that no private key crosses this boundary.
  ///
  /// [record] is `'membership'` (`op`: `admit`/`expel`), `'guardian'`
  /// (`op`: `designate`/`rotate`/`release`, with [guardianDid] and either
  /// [evidenceCid] or [unbackedReason] as that op requires), `'content_policy'`
  /// (`op`: `amend`, with [policy]; [memberDid] is unused) or `'office'` (`op`:
  /// `confer`/`revoke`, with [office]; [memberDid] is the holder, who co-signs a
  /// conferral). A guardian
  /// exchange reads the log: the evidence must already be in it, and a release
  /// on the guardian's own signature resolves the outgoing guardian from it
  /// rather than taking the caller's word.
  ///
  /// Returns `{record, op, polity_did, payload, bytes, cid, description,
  /// signers_required}`. `polity_did` is echoed back because the ask that goes
  /// on the wire must name the polity — the signer's node resolves the act in
  /// its own log, and `requestCosign` refuses an ask without it.
  /// Hand `bytes` and `description` to each signer in `signers_required`, then
  /// give `payload` back to [assembleSigned] **unchanged**: the signatures are
  /// checked against its canonical bytes, `decided_at` included, so a re-built
  /// payload will not verify.
  Map<String, dynamic> pendingChange({
    required String op,
    required String polityDid,
    required String memberDid,
    String record = 'membership',
    String rationale = '',
    List<String> deciderDids = const [],
    String? guardianDid,
    String? evidenceCid,
    String? unbackedReason,
    Map<String, dynamic>? policy,
    String? office,
  }) =>
      jsonDecode(_callSpecOut(_ffi._pending, {
        'record': record,
        'op': op,
        'polity_did': polityDid,
        'member_did': memberDid,
        'rationale': rationale,
        'deciders': deciderDids,
        if (guardianDid != null) 'guardian_did': guardianDid,
        if (evidenceCid != null) 'evidence_cid': evidenceCid,
        if (unbackedReason != null) 'unbacked_reason': unbackedReason,
        if (policy != null) 'policy': policy,
        if (office != null) 'office': office,
      })) as Map<String, dynamic>;

  /// Close a detached exchange: attach [signatures] and append.
  ///
  /// [payload] and [record] must be exactly what [pendingChange] returned. Each
  /// signature is verified against the payload here, so a wrong key or a
  /// tampered payload fails now rather than later as an unauthorized record —
  /// but whether the signers MEET the bar is still [verify]'s call.
  void assembleSigned({
    required Map<String, dynamic> payload,
    required List<({String did, String sig})> signatures,
    String record = 'membership',
  }) {
    _callSpec(_ffi._assemble, {
      'record': record,
      'payload': payload,
      'signatures':
          signatures.map((s) => {'did': s.did, 'sig': s.sig}).toList(),
    });
  }

  /// Resign [member] from the roll — self-signed by them alone.
  ///
  /// The roll records no deciders and cannot decide on their behalf: it cannot
  /// force somebody to stay. Refused by [verify] if the remaining polity could
  /// not self-govern, which is counted over SEASONED members — so three
  /// inducted members cannot shrink to two. See [affirmationState].
  void departMember({
    required String polityDid,
    required EthneKeypair member,
    String rationale = '',
  }) {
    _callSpec(_ffi._departMember, {
      'polity_did': polityDid,
      'member': {'did': member.did, 'priv': member.priv},
      'rationale': rationale,
    });
  }

  /// Expel [memberDid]. [deciders] must be majority + 1 of the SEASONED roll.
  ///
  /// The bar is higher than admission's on purpose: a bare majority that can
  /// expel is a bare majority that can manufacture itself a supermajority one
  /// departure at a time. The target is excluded from [deciders] and does not
  /// sign — this is the one roll act done *to* somebody rather than with them.
  void expelMember({
    required String polityDid,
    required String memberDid,
    String rationale = '',
    required List<EthneKeypair> deciders,
  }) {
    _callSpec(_ffi._expelMember, {
      'polity_did': polityDid,
      'member_did': memberDid,
      'rationale': rationale,
      'deciders': deciders.map((d) => {'did': d.did, 'priv': d.priv}).toList(),
    });
  }

  /// Record what this node saw, so a guardian edge can cite it.
  ///
  /// Returns `{cid, observer_did, off_roll}`. Pass `cid` as `evidenceCid` to
  /// [designateDerived] or [rotateGuardian].
  ///
  /// [observer] is whoever ACTUALLY looked, and the record is signed by exactly
  /// them — an observation cannot be put in somebody else's mouth. `off_roll`
  /// is false when that observer is the polity itself or sits on its roll: the
  /// observation is still real and still valid evidence, but an edge resting on
  /// it does not grade as *backed*, because a polity may not vouch for its own
  /// ground. Do not reach for a better-grading signer; show the grade.
  ///
  /// Each reading is one member as seen — `member`, `reputation`, the observed
  /// `guardian` (null means seen with nobody behind it, which is NOT the same as
  /// not having been observed), and `attestedAt` carried through as a stamp.
  Map<String, dynamic> observe({
    required String polityDid,
    required EthneKeypair observer,
    required List<
            ({String member, double reputation, String? guardian, int? attestedAt})>
        readings,
    bool opaqueBoundary = false,
    int? observedAt,
  }) =>
      jsonDecode(_callSpecOut(_ffi._observe, {
        'polity_did': polityDid,
        'observer': {'did': observer.did, 'priv': observer.priv},
        'readings': readings
            .map((r) => {
                  'member': r.member,
                  'reputation': r.reputation,
                  'guardian': r.guardian,
                  'attested_at': r.attestedAt,
                })
            .toList(),
        'opaque_boundary': opaqueBoundary,
        if (observedAt != null) 'observed_at': observedAt,
      })) as Map<String, dynamic>;

  /// Mark [memberDid] a derived (machine) party answering to [guardian].
  ///
  /// A majority of the SEASONED roll decides and the named guardian co-signs:
  /// answerability is accepted, never assigned. Passing no [guardian] charters a
  /// machine with nobody behind it — an honest state, and the one the
  /// machine-majority rule refuses to give an office to.
  ///
  /// An edge that IS claimed must carry evidence: either [evidenceCid] (a `cid`
  /// from [observe]) or [unbackedReason], which must say why nothing backs it.
  /// Neither, with a guardian named, is refused by [verify].
  void designateDerived({
    required String polityDid,
    required String memberDid,
    EthneKeypair? guardian,
    required List<EthneKeypair> deciders,
    String? evidenceCid,
    String? unbackedReason,
    String rationale = '',
  }) {
    _callSpec(_ffi._designateDerived, {
      'polity_did': polityDid,
      'member_did': memberDid,
      if (guardian != null)
        'guardian': {'did': guardian.did, 'priv': guardian.priv},
      'deciders': deciders.map((d) => {'did': d.did, 'priv': d.priv}).toList(),
      if (evidenceCid != null) 'evidence_cid': evidenceCid,
      if (unbackedReason != null) 'unbacked_reason': unbackedReason,
      'rationale': rationale,
    });
  }

  /// Point a designated member at a new [guardian] — its operator changed, or a
  /// machine chartered with nobody behind it acquires one.
  ///
  /// A majority plus the INCOMING guardian's consent; the outgoing one is
  /// released rather than held, because nobody is forced to keep serving. A
  /// rotation always claims an edge, so evidence is always required.
  void rotateGuardian({
    required String polityDid,
    required String memberDid,
    required EthneKeypair guardian,
    required List<EthneKeypair> deciders,
    String? evidenceCid,
    String? unbackedReason,
    String rationale = '',
  }) {
    _callSpec(_ffi._rotateGuardian, {
      'polity_did': polityDid,
      'member_did': memberDid,
      'guardian': {'did': guardian.did, 'priv': guardian.priv},
      'deciders': deciders.map((d) => {'did': d.did, 'priv': d.priv}).toList(),
      if (evidenceCid != null) 'evidence_cid': evidenceCid,
      if (unbackedReason != null) 'unbacked_reason': unbackedReason,
      'rationale': rationale,
    });
  }

  /// Record that a guardian edge is gone — the machine now answers to nobody.
  ///
  /// Two routes, and exactly one of them: [guardian] alone is the departing
  /// guardian stepping away on their own signature; [deciders] alone is the roll
  /// recording at a majority that the human is gone. A release carries no
  /// evidence — it claims the edge is GONE, and evidence of one present would
  /// argue the opposite. The member stays DERIVED; it is released, not
  /// un-designated.
  void releaseGuardian({
    required String polityDid,
    required String memberDid,
    EthneKeypair? guardian,
    List<EthneKeypair> deciders = const [],
    String rationale = '',
  }) {
    _callSpec(_ffi._releaseGuardian, {
      'polity_did': polityDid,
      'member_did': memberDid,
      if (guardian != null)
        'guardian': {'did': guardian.did, 'priv': guardian.priv},
      'deciders': deciders.map((d) => {'did': d.did, 'priv': d.priv}).toList(),
      'rationale': rationale,
    });
  }

  /// Which members are machines, who each answers to, and what backs it.
  ///
  /// Returns `{roll, derived, machine_majority, unguarded, edges}`, where each
  /// edge is `{member, guardian, guarded, backed, evidence, reason?, observer?,
  /// observed_at?, attested_at?}`.
  ///
  /// `backed` is a GRADE, not validity: an edge can be perfectly valid and
  /// unbacked, and the UI must show it as what it is rather than hide it. Where
  /// an edge is not backed, `reason` says why — the stated override, or that the
  /// observer was not outside the roll. `attested_at` is a stamp, not a verdict:
  /// a stale one may warn, and must not escalate.
  Map<String, dynamic> guardianState(String polityDid) {
    _check();
    final did = polityDid.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_ffi._guardianState(_handle, did, out) != 0) {
        throw EthneException(_ffi._err());
      }
      return jsonDecode(_ffi._takeString(out)) as Map<String, dynamic>;
    } finally {
      calloc.free(did);
      calloc.free(out);
    }
  }

  /// Recite one movement of [member]'s rite, returning the new record's CID.
  ///
  /// A rite is five movements in order, and [inductMember] must cite exactly
  /// these five CIDs — so collect what this returns. Three of the five carry
  /// content the core checks against the charter: movement 1 must name the
  /// chartered substrate, movement 4 must commit to exactly the in-force
  /// commitment keys, and movement 5 must name the charter's anchor (or none,
  /// where the charter is bare). Movements 2 and 3 carry nothing checkable.
  ///
  /// [attending] co-sign and must themselves be inducted — the substrate is
  /// transmitted by those who hold it. [statement] must be non-empty: a
  /// movement is performed, and an empty one was not.
  String reciteMovement({
    required String polityDid,
    required EthneKeypair member,
    /// The movement as its own JSON. Struct variants are maps —
    /// `{'Substrate': {'names': …}}`, `{'CommonVirtue': {'commits_to': […]}}`,
    /// `{'NonUltimacy': {'names_anchor': null}}` — and the two that carry
    /// nothing checkable are bare strings: `'Fallenness'`, `'Recognition'`.
    required Object movement,
    required String statement,
    List<EthneKeypair> attending = const [],
    String kind = 'Induction',
  }) =>
      _callSpecOut(_ffi._reciteMovement, {
        'polity_did': polityDid,
        'member': {'did': member.did, 'priv': member.priv},
        'kind': kind,
        'movement': movement,
        'statement': statement,
        'attending':
            attending.map((w) => {'did': w.did, 'priv': w.priv}).toList(),
      });

  /// Induct [member], completing their rite. [movementCids] must be exactly the
  /// five [reciteMovement] CIDs of *their own* rite, in order. [witnesses]
  /// co-sign and count only if they attended every movement; [member] consents.
  ///
  /// Until this runs, an admitted member is on the roll with no deciding
  /// weight — see [affirmationState].
  void inductMember({
    required String polityDid,
    required EthneKeypair member,
    required List<String> movementCids,
    List<EthneKeypair> witnesses = const [],
  }) {
    _callSpec(_ffi._inductMember, {
      'polity_did': polityDid,
      'member': {'did': member.did, 'priv': member.priv},
      'witnesses':
          witnesses.map((w) => {'did': w.did, 'priv': w.priv}).toList(),
      'movements': movementCids,
    });
  }

  /// Who holds the substrate, and what a vote actually costs:
  /// `{polity_did, roll, seasoned, admit_need, expel_need, can_contract,
  /// members:[{did, inducted, last_affirmed_at}…]}`.
  ///
  /// `seasoned` is the set the core counts majorities over, so an admitted but
  /// un-inducted member appears in `roll` and not in `seasoned`, and their
  /// signature does not count toward a threshold. `can_contract` is false when
  /// a departure or expulsion would drop the polity under the self-govern
  /// floor — which is why a three-member polity cannot shrink.
  ///
  /// This is a fold over what the log CLAIMS — it does NOT adjudicate. An
  /// append is not gated on the authority rules, so an invalid induction still
  /// moves `seasoned` here and is caught only by [verify]. Pair the two: this
  /// for the numbers, [verify] for whether they were earned.
  Map<String, dynamic> affirmationState(String polityDid) {
    _check();
    final did = polityDid.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_ffi._affirmationState(_handle, did, out) != 0) {
        throw EthneException(_ffi._err());
      }
      return jsonDecode(_ffi._takeString(out)) as Map<String, dynamic>;
    } finally {
      calloc.free(did);
      calloc.free(out);
    }
  }

  /// Authorize [envoy] to speak as the business. [authorizers] must be a
  /// majority of the current roll (or hold the envoy-authorizer office); the
  /// envoy co-signs (consent — no conscription).
  void authorizeEnvoy({
    required String polityDid,
    required EthneKeypair envoy,
    String rationale = '',
    required List<EthneKeypair> authorizers,
  }) {
    _callSpec(_ffi._authorizeEnvoy, {
      'polity_did': polityDid,
      'envoy_did': envoy.did,
      'rationale': rationale,
      'authorizers':
          authorizers.map((a) => {'did': a.did, 'priv': a.priv}).toList(),
      'envoy_priv': envoy.priv,
    });
  }

  /// The DIDs currently authorized to speak as the polity (its live envoys).
  List<String> envoyState(String polityDid) {
    _check();
    final did = polityDid.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_ffi._envoyState(_handle, did, out) != 0) {
        throw EthneException(_ffi._err());
      }
      final m = jsonDecode(_ffi._takeString(out)) as Map<String, dynamic>;
      return (m['envoys'] as List).cast<String>();
    } finally {
      calloc.free(did);
      calloc.free(out);
    }
  }

  /// Emit the polity's self-verifying `CommunityIdentity` border artifact
  /// (JSON), signed under its own [root] key. Anchors a self-contained bundle.
  String communityIdentity({
    required String polityDid,
    required String name,
    required EthneKeypair root,
  }) =>
      _callSpecOut(_ffi._communityIdentity, {
        'polity_did': polityDid,
        'name': name,
        'root_priv': root.priv,
        'root_pub': root.pub,
      });

  /// Emit a `SpeakerDelegation` (JSON) binding [envoyDid] to the polity, signed
  /// under the polity [root] key. This is the `delegation` half of a bundle.
  String envoyDelegation({
    required String polityDid,
    required String envoyDid,
    required EthneKeypair root,
  }) =>
      _callSpecOut(_ffi._envoyDelegation, {
        'polity_did': polityDid,
        'envoy_did': envoyDid,
        'root_priv': root.priv,
        'root_pub': root.pub,
      });

  /// Verify [pageJson] (a `Signed<BusinessPage>`) against THIS full charter log:
  /// page signature + charter validity + the signer being a current authorized
  /// envoy. The strongest check. True if authentic; else [lastError] has why.
  bool verifyBusinessPageFull(String pageJson) {
    _check();
    final s = pageJson.toNativeUtf8();
    try {
      return _ffi._verifyFull(_handle, s) == 0;
    } finally {
      calloc.free(s);
    }
  }

  /// Verify a business POST against the FULL charter log: post signature +
  /// charter validity (verify_all + check_authority) + the signer being a
  /// CURRENT authorized envoy. The strongest check, and it needs the polity's
  /// log — so it is what the BUSINESS's own nodes use, where a reader uses
  /// [EthneFfi.verifyBusinessPostBundle].
  bool verifyBusinessPostFull(String postJson) {
    _check();
    final s = postJson.toNativeUtf8();
    try {
      return _ffi._verifyPostFull(_handle, s) == 0;
    } finally {
      calloc.free(s);
    }
  }

  /// Publish this polity's roll as KC's `MemberRoll`, signed under its ROOT key,
  /// returning the `Signed<MemberRoll>` JSON.
  ///
  /// Border artifact #6 (D26): what gives a polity's members a real anonymous
  /// channel in the compact tier, which models communities and speakers but has
  /// no member roster of its own.
  ///
  /// Takes [root] — the POLITY's own keypair, not a member's. Only its holder can
  /// publish a roll, which is a fact about who may act rather than an obstacle.
  /// Lives on the archive because, unlike signing a business page, the roll is
  /// READ FROM THIS LOG as of [asOf] (default now); [publishedAt] defaults to it.
  ///
  /// Publishing a shorter roll REMOVES NOBODY: the compact tier unions rolls
  /// rather than superseding them, so a departure recorded here does not close
  /// the channel of whoever left. [asOf] crosses as provenance, not authority.
  String signMemberRoll({
    required String polityDid,
    required EthneKeypair root,
    int? asOf,
    int? publishedAt,
  }) =>
      _callSpecOut(_ffi._rollSign, {
        'polity_did': polityDid,
        'root_priv': root.priv,
        'root_pub': root.pub,
        if (asOf != null) 'as_of': asOf,
        if (publishedAt != null) 'published_at': publishedAt,
      });

  /// Verify [rollJson] against THIS full charter log: everything
  /// [EthneFfi.verifyMemberRoll] checks, plus charter validity and the roll
  /// naming exactly the members this log says the polity had at the roll's
  /// `as_of`.
  ///
  /// This is the check a compact tier CANNOT make — it has no dependency on this
  /// tier's charter, so it can only establish the publisher. Keep the two answers
  /// apart when reporting them: they are different questions.
  bool verifyMemberRollFull(String rollJson) {
    _check();
    final s = rollJson.toNativeUtf8();
    try {
      return _ffi._rollVerifyFull(_handle, s) == 0;
    } finally {
      calloc.free(s);
    }
  }

  /// Replace the polity's content policy (Ethne D37), with every decider's key
  /// in this process — tools and tests; a live roll uses [pendingChange] with
  /// `record: 'content_policy'`. [policy] is `{operator_bound_required,
  /// min_tier, daily_post_cap, labels: {label: Allow|Warn|Hide}}`. A majority
  /// tightens; loosening anything needs a majority + 1, which [verify] decides.
  void amendContentPolicy({
    required String polityDid,
    required Map<String, dynamic> policy,
    String rationale = '',
    required List<EthneKeypair> deciders,
  }) {
    _callSpec(_ffi._amendContentPolicy, {
      'polity_did': polityDid,
      'policy': policy,
      'rationale': rationale,
      'deciders': deciders.map((d) => {'did': d.did, 'priv': d.priv}).toList(),
    });
  }

  /// Confer [office] (e.g. `'Moderator'`) on [holder]: [deciders] a majority,
  /// the holder consenting with their own key.
  void conferOffice({
    required String polityDid,
    required String office,
    required EthneKeypair holder,
    String rationale = '',
    required List<EthneKeypair> deciders,
  }) {
    _callSpec(_ffi._conferOffice, {
      'polity_did': polityDid,
      'office': office,
      'holder_did': holder.did,
      'holder_priv': holder.priv,
      'rationale': rationale,
      'deciders': deciders.map((d) => {'did': d.did, 'priv': d.priv}).toList(),
    });
  }

  /// Revoke [office] from [holderDid]: [deciders] a majority, holder excluded.
  void revokeOffice({
    required String polityDid,
    required String office,
    required String holderDid,
    String rationale = '',
    required List<EthneKeypair> deciders,
  }) {
    _callSpec(_ffi._revokeOffice, {
      'polity_did': polityDid,
      'office': office,
      'holder_did': holderDid,
      'rationale': rationale,
      'deciders': deciders.map((d) => {'did': d.did, 'priv': d.priv}).toList(),
    });
  }

  /// The content policy this log says is in force now: `{policy, set_by,
  /// moderators}`. Only accepted amendments are read; moderators are inducted
  /// holders of `Moderator`.
  Map<String, dynamic> contentPolicyState(String polityDid) {
    _check();
    final did = polityDid.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_ffi._contentPolicyState(_handle, did, out) != 0) {
        throw EthneException(_ffi._err());
      }
      return jsonDecode(_ffi._takeString(out)) as Map<String, dynamic>;
    } finally {
      calloc.free(did);
      calloc.free(out);
    }
  }

  /// Mint the polity's policy artifact from this log, now, under [root] — the
  /// POLITY's own keypair, as for [signMemberRoll]. Its `seq` is the log's
  /// length, so every later artifact is newer, including one that only changes
  /// who moderates.
  String signContentPolicy({
    required String polityDid,
    required EthneKeypair root,
    bool hubs = false,
  }) =>
      _callSpecOut(_ffi._contentPolicySign, {
        'polity_did': polityDid,
        'root_priv': root.priv,
        // Carry the polity's relay roster (its area hubs, Ethne D38) inside,
        // so a follower learns where its community's hubs are.
        if (hubs) 'hubs': true,
      });

  /// A rendezvous operator ([member], holding `RendezvousOperator`) declares
  /// where its relay listens and the geohash [areas] it is a hub for (Ethne
  /// D36/D38). Signed by the member alone.
  void declareRelayEndpoint({
    required String polityDid,
    required EthneKeypair member,
    required String atUuid,
    required String host,
    required int port,
    List<String> areas = const [],
  }) {
    _callSpec(_ffi._declareRelayEndpoint, {
      'polity_did': polityDid,
      'member': {'did': member.did, 'priv': member.priv},
      'at_uuid': atUuid,
      'host': host,
      'port': port,
      'areas': areas,
    });
  }

  /// The current charter state: `{polity_did, chartered, dissolved, substrate,
  /// commitments, members:[did…]}`.
  Map<String, dynamic> charterState(String polityDid) {
    _check();
    final did = polityDid.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_ffi._charterState(_handle, did, out) != 0) {
        throw EthneException(_ffi._err());
      }
      return jsonDecode(_ffi._takeString(out)) as Map<String, dynamic>;
    } finally {
      calloc.free(did);
      calloc.free(out);
    }
  }

  /// Verify every signature and every governance rule. Returns true if both
  /// pass; on failure returns false and sets [lastError].
  bool verify() {
    _check();
    return _ffi._verify(_handle) == 0;
  }

  /// The last error message (e.g. after [verify] returns false).
  String lastError() => _ffi._err();

  /// Serialize the whole log (round-trips through [EthneFfi.loadArchive]).
  String dumpJson() {
    _check();
    final out = calloc<Pointer<Utf8>>();
    try {
      if (_ffi._dumpJson(_handle, out) != 0) throw EthneException(_ffi._err());
      return _ffi._takeString(out);
    } finally {
      calloc.free(out);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ffi._archiveFree(_handle);
  }
}

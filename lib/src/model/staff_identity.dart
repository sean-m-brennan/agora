// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// This node's STAFF identity and the charter log of the polity it belongs to
// (Phase 3 P3.3, SOCIAL_APP_PLAN.md §2.2). A business is an Ethne polity, and a
// staff member is a node holding (a) its own Ethne keypair and (b) a copy of the
// polity's append-only charter log. Both have to live somewhere on the node
// before the app can show a roll or co-sign anything:
//
//   * The roll and the guardian edges are read out of the LOG — affirmationState
//     and guardianState both take an archive. Ethne offers no path-based
//     persistence, only newArchive() / dumpJson() / loadArchive(dump), so the app
//     owns the file.
//   * Signing is done with the member's OWN key, on their own node, which is the
//     entire point of the detached two-phase exchange: the key never moves. A key
//     that is not on this node cannot sign here.
//
// Stored as a small JSON file under the daemon root, alongside the tie settings
// the app already keeps there, and modelled on TieSettingsStore: all I/O is
// best-effort and never throws into the app. A missing or corrupt file means
// "this node is not staff of any polity", which is an honest state the UI shows
// rather than an error.
//
// NOTE ON THE KEY AT REST. The private key is written in the clear. That follows
// from the design — it must be on this node to be usable — but this file adds no
// at-rest protection, and a reader of the node's disk can sign as this member.
// Protecting it is a separate concern and is deliberately not solved here.

import 'dart:convert';
import 'dart:io';

import '../ffi/ethne_bindings.dart';

/// This node's membership of one polity: who it signs as, and the charter log it
/// reads the roll out of. [archive] is an Ethne `dumpJson()` payload, carried as
/// decoded JSON so the file stays inspectable — a governance record nobody can
/// read is a governance record nobody can audit.
class StaffIdentity {
  StaffIdentity({
    required this.polityDid,
    required this.self,
    required this.archive,
    this.root,
  });

  /// The polity (business) this node is staff of.
  final String polityDid;

  /// This node's own Ethne keypair — the one [EthneFfi.signDetached] uses.
  final EthneKeypair self;

  /// The polity's charter log, as `dumpJson()` wrote it.
  final Map<String, dynamic> archive;

  /// The POLITY's own keypair, present only on the node that holds it.
  ///
  /// Publishing a member roll is signing under the polity's root key, so only
  /// this node can do it — and on most staff nodes this is null, which is the
  /// ordinary case and not a degraded one. It is kept apart from [self]: a
  /// member's key speaks for a member, and the root key speaks for the polity.
  final EthneKeypair? root;

  Map<String, dynamic> toJson() => {
        'polity_did': polityDid,
        'self': {'did': self.did, 'priv': self.priv, 'pub': self.pub},
        if (root != null)
          'root': {'did': root!.did, 'priv': root!.priv, 'pub': root!.pub},
        'archive': archive,
      };

  /// Parse a stored identity, or null when the payload is not a complete one.
  /// Partial state is refused rather than half-loaded: a roster read against an
  /// archive with no key beside it would offer a sign button that cannot sign.
  static StaffIdentity? fromJson(Map<String, dynamic> j) {
    final polity = j['polity_did'];
    final self = j['self'];
    final archive = j['archive'];
    if (polity is! String || polity.isEmpty) return null;
    if (self is! Map) return null;
    final did = self['did'];
    final priv = self['priv'];
    final pub = self['pub'];
    if (did is! String || did.isEmpty) return null;
    if (priv is! Map || pub is! Map) return null;

    // The dump is accepted either decoded (how this store writes it) or as the
    // raw string dumpJson() returned, so a file hand-made from a cohort script
    // loads too.
    Map<String, dynamic>? log;
    if (archive is Map) {
      log = archive.cast<String, dynamic>();
    } else if (archive is String && archive.isNotEmpty) {
      try {
        final decoded = jsonDecode(archive);
        if (decoded is Map) log = decoded.cast<String, dynamic>();
      } catch (_) {
        return null;
      }
    }
    if (log == null) return null;

    // An ABSENT root is a complete identity for a node that cannot publish. A
    // root that is present and unreadable is not absent — it is corrupt, and a
    // node that half-holds the polity's key should say it holds nothing rather
    // than offer a publish button that cannot sign.
    EthneKeypair? rootKey;
    if (j.containsKey('root')) {
      final r = j['root'];
      if (r is! Map) return null;
      final rdid = r['did'];
      final rpriv = r['priv'];
      final rpub = r['pub'];
      if (rdid is! String || rdid.isEmpty) return null;
      if (rpriv is! Map || rpub is! Map) return null;
      rootKey = EthneKeypair(
        rdid,
        rpriv.cast<String, dynamic>(),
        rpub.cast<String, dynamic>(),
      );
    }

    return StaffIdentity(
      polityDid: polity,
      self: EthneKeypair(
        did,
        priv.cast<String, dynamic>(),
        pub.cast<String, dynamic>(),
      ),
      archive: log,
      root: rootKey,
    );
  }
}

/// A best-effort JSON-file store for [StaffIdentity], following
/// [TieSettingsStore]: construct with the target file, [load] once at startup,
/// [save] when the log moves on. Every method swallows I/O errors.
class StaffIdentityStore {
  StaffIdentityStore(this.file);

  final File file;

  /// Null when this node is not staff of any polity — the ordinary case, and not
  /// an error.
  StaffIdentity? identity;

  /// Load from disk. On any error (missing, unreadable, malformed, incomplete),
  /// leaves [identity] null. Returns this for chaining.
  Future<StaffIdentityStore> load() async {
    try {
      if (await file.exists()) {
        final obj = jsonDecode(await file.readAsString());
        if (obj is Map<String, dynamic>) {
          identity = StaffIdentity.fromJson(obj);
        }
      }
    } catch (_) {
      // not staff, as far as this node can tell
    }
    return this;
  }

  /// Persist the current identity. Best-effort; never throws. With no identity
  /// there is nothing to write, and any existing file is left alone.
  Future<void> save() async {
    final id = identity;
    if (id == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(id.toJson()));
    } catch (_) {
      // best-effort
    }
  }

  /// Replace the stored charter log after appending to it, keeping the polity and
  /// the key. Call [save] (debounced by the caller) to make it durable.
  void updateArchive(Map<String, dynamic> dump) {
    final id = identity;
    if (id == null) return;
    identity = StaffIdentity(
      polityDid: id.polityDid,
      self: id.self,
      archive: dump,
      root: id.root,
    );
  }
}

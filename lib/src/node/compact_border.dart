// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The production [CompactBorder]: this staff node's replica of its community's
// compacts ([EthneKc]), its charter log (for the roll's mandate, Ethne D40) and
// the keys it holds. The governance node holds the polity root key and is the
// envoy and the Inductor; another staff node holds only its own member key and
// sits as a seated examiner.

import '../ffi/ethne_bindings.dart';
import 'compact_engine.dart';

class EthneCompactBorder implements CompactBorder {
  EthneCompactBorder({
    required EthneFfi ffi,
    required EthneArchive Function() charter,
    required EthneKc kc,
    required this.polityDid,
    required EthneKeypair self,
    EthneKeypair? root,
  })  : _ffi = ffi,
        _charterOf = charter,
        _kc = kc,
        _self = self,
        _root = root;

  final EthneFfi _ffi;
  /// The charter log as it stands now: the service reopens it after an act, so a
  /// handle taken once would outlive it.
  final EthneArchive Function() _charterOf;
  EthneArchive get _charter => _charterOf();
  final EthneKc _kc;
  final EthneKeypair _self;
  final EthneKeypair? _root;

  @override
  final String polityDid;

  @override
  String get selfDid => _self.did;

  @override
  bool get governs => _root != null;

  EthneKeypair get _rootOrThrow =>
      _root ?? (throw EthneException('only the node holding the polity root key may do this'));

  /// The replica handle, for the caller that owns its lifetime.
  EthneKc get replica => _kc;

  @override
  Map<String, dynamic> border() =>
      _kc.border(_charter, polityDid: polityDid, rootPriv: _rootOrThrow.priv, envoyDid: _self.did);

  @override
  Map<String, dynamic> riteDraft(String inductorDid) =>
      _kc.riteDraft(_charter, polityDid: polityDid, rootPriv: _rootOrThrow.priv, inductorDid: inductorDid);

  @override
  Map<String, dynamic> riteSeal(Map<String, dynamic> spec) =>
      _kc.riteSeal({...spec, 'root_priv': _rootOrThrow.priv});

  @override
  Map<String, dynamic> claims(String compact, List<String> counterparties) => _kc.claims(_charter,
      polityDid: polityDid, compact: compact, counterparties: counterparties, envoyPriv: _self.priv);

  @override
  Map<String, dynamic> verdicts(String compact, String presenter, bool accepted) => _kc.verdicts(_charter,
      polityDid: polityDid, compact: compact, presenter: presenter, accepted: accepted, envoyPriv: _self.priv);

  @override
  Map<String, dynamic> sponsor(String compact, String entrant) =>
      _kc.sponsor(_charter, polityDid: polityDid, compact: compact, entrant: entrant, envoyPriv: _self.priv);

  @override
  Map<String, dynamic> examiners(List<Map<String, dynamic>> seats) =>
      _kc.examiners(polityDid: polityDid, rootPriv: _rootOrThrow.priv, seats: seats);

  @override
  Map<String, dynamic> sealDraft(String compact, List<String> participants) =>
      _kc.sealDraft(compact: compact, participants: participants);

  @override
  Map<String, dynamic> sealSign(String manifest) => _kc.sealSign(_charter,
      manifest: manifest, polityDid: polityDid, signerDid: _self.did, signerPriv: _self.priv);

  @override
  Map<String, dynamic> sealAssemble(String manifest, List<Map<String, dynamic>> sigs) =>
      _kc.sealAssemble(manifest, sigs);

  @override
  Map<String, dynamic> sealIngest(String sealed) => _kc.sealIngest(sealed);

  @override
  Map<String, dynamic> conductDraft(String kind, String compact, List<String> reporters, String subject,
          {String? designation}) =>
      _ffi.kcConductDraft(_charter, {
        'polity_did': polityDid,
        'compact': compact,
        'kind': kind,
        'reporters': reporters,
        'subject': subject,
        if (designation != null) 'designation': designation,
      });

  @override
  Map<String, dynamic> conductSign(String compact, {Map<String, dynamic>? payload, String? bytes}) =>
      _kc.conductSign(_charter,
          polityDid: polityDid, compact: compact, payload: payload, bytes: bytes, envoyPriv: _self.priv);

  @override
  Map<String, dynamic> conductAssemble(Map<String, dynamic> payload, List<Map<String, dynamic>> sigs) =>
      _kc.conductAssemble(payload, sigs);

  @override
  Map<String, dynamic> ingest(String hex) => _kc.ingest(hex);

  @override
  List<Map<String, dynamic>> deliveries() => _kc.deliveries();

  @override
  String signOwn(String bytesHex) => _ffi.signDetached(priv: _self.priv, bytesHex: bytesHex);

  @override
  String receiptSign(String cid) => _ffi.kcReceiptSign(cid, _self.priv);

  @override
  bool receiptVerify(String cid, String did, String sig) =>
      _ffi.kcReceiptVerify(cid: cid, did: did, sig: sig);

  @override
  String viewSign(String node) => _kc.viewSign(polityDid: polityDid, rootPriv: _rootOrThrow.priv, node: node);

  @override
  String dump() => _kc.dump();
}

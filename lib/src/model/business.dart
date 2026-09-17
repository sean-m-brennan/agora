// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Business: the app-side view of a business ad (Phase 3 P3.2, "businesses near
// me"). A business is an Ethne polity; its PAGE is an opaque, self-verifying
// Ethne bundle ({page, delegation} proving polity-root → envoy → page).
//
// TWO TRUST LAYERS MEET HERE, and they stay separate:
//   * the AT layer, done by the core before the event reaches us — a detached
//     Ed25519 signature binding WHO advertised, HOW satisfied they are, and
//     WHICH page bytes they meant, plus content-id dedup;
//   * the ETHNE layer, done HERE — the bundle proves the page really speaks for
//     the polity. The core never parses the bundle; the app does, through
//     EthneFfi.verifyBusinessPageBundle.
//
// An ad is never relayed. Only a CUSTOMER carries a business's page, and it
// re-advertises in the FIRST PERSON with its own satisfaction, so every ad on
// the wire is somebody vouching for the business by name. An unhappy customer
// simply goes quiet — nothing negative is ever published, so this model has no
// negative to represent.

import 'dart:convert';

import '../ffi/at_events_bindings.dart';

/// One received business ad: one advertiser vouching for one page version.
class BusinessAd {
  const BusinessAd({
    required this.advertiserUuid,
    required this.polity,
    required this.adId,
    required this.satisfaction,
    required this.seq,
    required this.ts,
    required this.bundle,
  });

  /// The ADVERTISER's raw 16-byte uuid — signature-bound by the core, not taken
  /// from the wire envelope. Either the business's own node or a customer.
  final List<int> advertiserUuid;

  /// The business's Ethne DID — the directory key.
  final String polity;

  /// The blake2b content-address of the canonical ad (lowercase hex): the dedup
  /// key, and what forecloses replay.
  final String adId;

  /// The advertiser's declared satisfaction 0..4, or [agoraBusinessSatSelf]
  /// when the business is advertising its own page.
  final int satisfaction;

  /// The page version this advertiser is carrying.
  final int seq;

  /// The advertiser's send time (epoch seconds).
  final double ts;

  /// The OPAQUE Ethne page bundle, unverified at this point.
  final String bundle;

  /// True when this is the business speaking for itself. Self-vouching is free,
  /// so it buys no social proof — [Business.vouch] excludes it.
  bool get isSelfAd => satisfaction == agoraBusinessSatSelf;

  /// Advertiser uuid as lowercase hex — the endorser key.
  String get advertiserHex =>
      advertiserUuid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Build an ad from a decoded [agoraEventBusinessAd] event.
  factory BusinessAd.fromEvent(AtRawEvent e) => BusinessAd(
        advertiserUuid: e.uuid,
        polity: e.businessPolity,
        adId: e.businessAdId,
        satisfaction: e.businessSatisfaction,
        seq: e.businessSeq,
        ts: e.businessTs,
        bundle: e.businessBundle,
      );
}

/// The page fields carried inside an Ethne bundle. Parsed for DISPLAY and for
/// the distance term only — parsing is not verification, and a parsed page that
/// failed [BusinessDirectory]'s verifier never enters the directory.
class BusinessPage {
  const BusinessPage({
    required this.polity,
    required this.name,
    required this.category,
    required this.description,
    required this.locality,
    required this.contact,
    required this.seq,
  });

  final String polity;
  final String name;
  final String category;
  final String description;

  /// The page's coarse GEOHASH BUCKET — its geographic anchor, the same form and
  /// precision as a peer's opt-in position. A business address is public, so
  /// unlike a person's position this is advertised openly, but it stays a
  /// bucket. Empty means the page is unplaced and cannot rank by distance.
  final String locality;

  final String contact;

  /// The page version the envoy signed.
  final int seq;

  /// Parse the `{"page":{"payload":{...}}}` half of an Ethne bundle. Returns
  /// null when the bundle is not JSON or carries no page payload — the display
  /// falls back to the DID, and the entry simply cannot rank by distance.
  static BusinessPage? parse(String bundleJson) {
    if (bundleJson.isEmpty) return null;
    Object? root;
    try {
      root = jsonDecode(bundleJson);
    } on FormatException {
      return null;
    }
    if (root is! Map) return null;
    final page = root['page'];
    if (page is! Map) return null;
    final payload = page['payload'];
    if (payload is! Map) return null;
    String str(String key) {
      final v = payload[key];
      return v is String ? v : '';
    }

    final seqv = payload['seq'];
    return BusinessPage(
      polity: str('polity'),
      name: str('name'),
      category: str('category'),
      description: str('description'),
      locality: str('locality'),
      contact: str('contact'),
      seq: seqv is int ? seqv : 0,
    );
  }
}

/// One business in the directory: the newest page version seen, plus everyone
/// who vouched for it.
///
/// [endorsers] holds CUSTOMERS only, keyed by advertiser hex — one entry per
/// person, their most recent ad. The business's own ad is deliberately absent:
/// a page nobody patronizes has no endorsers, which is the whole point of
/// distribution-by-patronage.
class Business {
  Business({
    required this.polity,
    required this.bundle,
    required this.seq,
    required this.ts,
    this.page,
    this.selfAdvertised = false,
    Map<String, BusinessAd>? endorsers,
  }) : endorsers = endorsers ?? <String, BusinessAd>{};

  /// The Ethne DID — the directory key.
  final String polity;

  /// The newest verified page bundle held for this business.
  String bundle;

  /// That page's version.
  int seq;

  /// When the page we hold was last advertised to us (epoch seconds).
  double ts;

  /// The parsed page, or null when the bundle carried no readable payload.
  BusinessPage? page;

  /// True once the business itself has advertised to us directly (as opposed to
  /// the page arriving only through customers). Display-only — it grants no
  /// ranking credit.
  bool selfAdvertised;

  /// Customer endorsements, keyed by advertiser hex. Most recent per advertiser.
  final Map<String, BusinessAd> endorsers;

  /// Display name: the page's name, falling back to the DID when unparsed.
  String get displayName {
    final n = page?.name ?? '';
    return n.isNotEmpty ? n : polity;
  }

  /// The page's coarse geohash bucket, or empty when unplaced.
  String get locality => page?.locality ?? '';

  /// The most recent moment anyone vouched for this business (epoch seconds),
  /// including the business's own ad if that is all we have.
  double get lastHeardAt {
    var newest = ts;
    for (final ad in endorsers.values) {
      if (ad.ts > newest) newest = ad.ts;
    }
    return newest;
  }
}

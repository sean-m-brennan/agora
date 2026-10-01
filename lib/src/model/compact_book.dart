// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// What communities say about their kith-covenant compacts (SOCIAL_APP_PLAN Phase 5;
// Ethne D39). Each community's governance node signs a small compact VIEW from
// the compact archive it holds and verifies: the compacts it sits in, how every
// other community it knows stands with it, and which Agora node speaks for it.
// The view rides the policy carrier under the key "<did>#compact".
//
// A reader trusts the view of a community it follows as it trusts that
// community's policy: it is the community's own word, verified against its root
// key. Nothing here reads a compact archive. That is the staged trust path: a
// reader verifying the whole archive waits on AT carrying archives that size.

/// The suffix a compact view's carrier key carries after the community's DID.
const String compactViewSuffix = '#compact';

/// The carrier key of [communityDid]'s compact view.
String compactViewKey(String communityDid) => '$communityDid$compactViewSuffix';

/// The community a carrier key names, or null when it is not a view key.
String? communityOfViewKey(String key) => key.endsWith(compactViewSuffix)
    ? key.substring(0, key.length - compactViewSuffix.length)
    : null;

/// A community's own standing words, from best to worst.
enum CompactStanding { inCompact, probationary, outside, denied, anathema }

CompactStanding standingOfWord(String w) => switch (w) {
      'in_compact' => CompactStanding.inCompact,
      'probationary' => CompactStanding.probationary,
      'denied' => CompactStanding.denied,
      'anathema' => CompactStanding.anathema,
      _ => CompactStanding.outside,
    };

/// How a standing reads on a badge, or null where nothing is worth saying.
String? standingBadge(CompactStanding s) => switch (s) {
      CompactStanding.inCompact => 'in compact with yours',
      CompactStanding.probationary => 'probationary in your compact',
      CompactStanding.denied => 'refused by your compact',
      CompactStanding.anathema => 'anathema in your compact',
      CompactStanding.outside => null,
    };

/// One verified compact view.
class CompactView {
  CompactView({
    required this.communityDid,
    required this.node,
    required this.seq,
    required this.compacts,
    required this.standings,
    required this.bundle,
  });

  /// Build from what `ethne_compact_view_verify` returned and the bundle it read.
  factory CompactView.fromVerified(Map<String, dynamic> v, String bundle) => CompactView(
        communityDid: v['community_did'] as String,
        node: v['node'] as String? ?? '',
        seq: (v['seq'] as num).toInt(),
        compacts: [
          for (final c in (v['compacts'] as List? ?? const []))
            if (c is Map)
              (
                label: c['label'] as String,
                id: c['id'] as String,
                members: [for (final m in (c['members'] as List? ?? const [])) m as String],
              ),
        ],
        standings: {
          for (final e in ((v['standings'] as Map?) ?? const {}).entries)
            e.key as String: standingOfWord(e.value as String),
        },
        bundle: bundle,
      );

  final String communityDid;

  /// The AT uuid (32 hex) of the community's governance node.
  final String node;
  final int seq;
  final List<({String label, String id, List<String> members})> compacts;
  final Map<String, CompactStanding> standings;

  /// The signed bundle, to carry on and to re-verify on load.
  final String bundle;

  /// The verified map back again, as `ethne_compact_standing_verdict` takes it.
  Map<String, dynamic> toVerdictInput() => {
        'community_did': communityDid,
        'standings': {
          for (final e in standings.entries)
            e.key: switch (e.value) {
              CompactStanding.inCompact => 'in_compact',
              CompactStanding.probationary => 'probationary',
              CompactStanding.denied => 'denied',
              CompactStanding.anathema => 'anathema',
              CompactStanding.outside => 'outside',
            },
        },
      };
}

/// Verifies a compact view bundle; null when it does not verify.
typedef ViewVerifier = Map<String, dynamic>? Function(String bundle);

/// Every compact view this reader has heard, the highest seq per community.
class CompactBook {
  final Map<String, CompactView> views = {};

  /// Take in a verified view. True when it is new or newer than the one held.
  bool hear(CompactView v) {
    final held = views[v.communityDid];
    if (held != null && held.seq >= v.seq) return false;
    views[v.communityDid] = v;
    return true;
  }

  /// How [other] stands with the communities in [readerCommunities] (the ones
  /// this reader follows): the best reading any of their views gives, so a
  /// community is "in compact with yours" when any of yours says so. A strictly
  /// bad reading (denied, anathema) from any of them wins over a good one,
  /// because a community you follow has said it cannot stand with them.
  CompactStanding? standingOf(String other, Iterable<String> readerCommunities) {
    CompactStanding? best;
    for (final c in readerCommunities) {
      if (c == other) return null;
      final s = views[c]?.standings[other];
      if (s == null) continue;
      if (s == CompactStanding.anathema || s == CompactStanding.denied) return s;
      if (best == null || s.index < best.index) best = s;
    }
    return best;
  }

  /// The communities that share a compact with any of [readerCommunities]:
  /// the ones a reader's businesses and hubs may be offered from.
  Set<String> compactMates(Iterable<String> readerCommunities) => {
        for (final c in readerCommunities)
          for (final e in (views[c]?.standings ?? const <String, CompactStanding>{}).entries)
            if (e.value == CompactStanding.inCompact || e.value == CompactStanding.probationary) e.key,
      };

  /// The governance node a community names in its own view, or null.
  String? nodeOf(String communityDid) {
    final n = views[communityDid]?.node;
    return (n == null || n.isEmpty) ? null : n;
  }

  Map<String, dynamic> toJson() => {
        'views': {for (final v in views.values) v.communityDid: v.bundle},
      };

  /// Load what [toJson] wrote, re-verifying every bundle; one that no longer
  /// verifies is dropped rather than trusted.
  static CompactBook fromJson(Map<String, dynamic> j, ViewVerifier verify) {
    final b = CompactBook();
    for (final e in ((j['views'] as Map?) ?? const {}).entries) {
      final bundle = e.value;
      if (bundle is! String) continue;
      final v = verify(bundle);
      if (v == null || v['community_did'] != e.key) continue;
      b.hear(CompactView.fromVerified(v, bundle));
    }
    return b;
  }
}

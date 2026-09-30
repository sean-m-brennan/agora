// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// A community's content policy, as this reader holds and applies it (Phase 4,
// Ethne D37).
//
// A community is an Ethne polity. Its roll decides how content posted in its
// name is moderated — what an author must meet, and what each label does — and
// its root key signs the result. A Moderator the roll seats labels posts alone.
// This reader APPLIES a policy only for a community it follows, and may set it
// aside for itself: moderation here is local and per-community, never global.
// A post made in a community this reader does not follow is shown unmoderated.
//
// THIS FILE DECIDES NOTHING CRYPTOGRAPHIC. Whether a policy is the community's,
// whether a label's signer is a moderator it lists, and the show / warn / hide
// verdict itself are computed by the Ethne cdylib (ethne_content_policy_verdict)
// through [CommunityCrypto], so this app and the live cohort's driver run the
// same code over the same bytes. What lives here is the reader's own state: the
// policies it holds, the labels it has received, which policies it has switched
// off, and how many posts each author has made in each community today.

import 'post.dart';

/// What a policy's label does, loosest first (Ethne `LabelAction`).
enum LabelAction {
  allow,
  warn,
  hide;

  static LabelAction parse(Object? v) => switch (v) {
        'Hide' => LabelAction.hide,
        'Warn' => LabelAction.warn,
        _ => LabelAction.allow,
      };

  String get wire => switch (this) {
        LabelAction.allow => 'Allow',
        LabelAction.warn => 'Warn',
        LabelAction.hide => 'Hide',
      };
}

/// One community's policy, read out of a VERIFIED artifact.
class CommunityPolicy {
  const CommunityPolicy({
    required this.communityDid,
    required this.seq,
    required this.operatorBoundRequired,
    required this.minTier,
    required this.dailyPostCap,
    required this.labels,
    required this.moderators,
    required this.bundle,
  });

  /// From what `EthneFfi.verifyContentPolicy` returned for [bundle]:
  /// `{community_did, seq, policy, moderators}`.
  factory CommunityPolicy.fromVerified(
      Map<String, dynamic> read, String bundle) {
    final p = (read['policy'] as Map?)?.cast<String, dynamic>() ?? const {};
    final labels = <String, LabelAction>{};
    final raw = p['labels'];
    if (raw is Map) {
      for (final e in raw.entries) {
        labels['${e.key}'] = LabelAction.parse(e.value);
      }
    }
    return CommunityPolicy(
      communityDid: read['community_did'] as String? ?? '',
      seq: (read['seq'] as num?)?.toInt() ?? 0,
      operatorBoundRequired: p['operator_bound_required'] == true,
      minTier: (p['min_tier'] as num?)?.toInt() ?? 0,
      dailyPostCap: (p['daily_post_cap'] as num?)?.toInt(),
      labels: labels,
      moderators: ((read['moderators'] as List?) ?? const [])
          .whereType<String>()
          .toList(growable: false),
      bundle: bundle,
    );
  }

  final String communityDid;

  /// The artifact's version: the charter log's length when it was minted. A
  /// higher seq replaces a lower one whole.
  final int seq;
  final bool operatorBoundRequired;
  final int minTier;
  final int? dailyPostCap;
  final Map<String, LabelAction> labels;

  /// Members who may label in the community's name.
  final List<String> moderators;

  /// The signed artifact itself, exactly as it verified. What the verdict and
  /// label checks are run against, and what this node carries if it follows.
  final String bundle;

  /// The policy as Ethne's `ContentPolicy` JSON, for an amendment.
  Map<String, dynamic> get rules => {
        'operator_bound_required': operatorBoundRequired,
        'min_tier': minTier,
        'daily_post_cap': dailyPostCap,
        'labels': {for (final e in labels.entries) e.key: e.value.wire},
      };
}

/// How this reader shows one post.
enum PolicyAction { show, warn, hide }

/// One reason a verdict gives, in the library's terms.
class PolicyReason {
  const PolicyReason(this.code, this.detail);

  factory PolicyReason.fromJson(Map<String, dynamic> j) =>
      PolicyReason(j['code'] as String? ?? '', j);

  /// `operator_unbound`, `below_min_tier`, `over_daily_cap` or `label`.
  final String code;
  final Map<String, dynamic> detail;

  /// Who applied a label: 'author', or a moderator's DID.
  String get labelledBy => detail['by'] as String? ?? '';

  /// Plain words for a person reading why a post is hidden or behind a warning.
  String get describe => switch (code) {
        'operator_unbound' => 'its author has no operator answering for them',
        'below_min_tier' =>
          'its author is below trust tier ${detail['min_tier']} for you',
        'over_daily_cap' =>
          'its author is over the limit of ${detail['cap']} posts a day',
        'label' => labelledBy == 'author'
            ? 'labelled "${detail['label']}" by its author'
            : 'labelled "${detail['label']}" by a moderator',
        _ => code,
      };
}

/// The show / warn / hide decision for one post, and why.
class PolicyVerdict {
  const PolicyVerdict({
    required this.communityDid,
    required this.action,
    required this.reasons,
    required this.tags,
  });

  factory PolicyVerdict.fromJson(Map<String, dynamic> j) => PolicyVerdict(
        communityDid: j['community_did'] as String? ?? '',
        action: switch (j['action']) {
          'hide' => PolicyAction.hide,
          'warn' => PolicyAction.warn,
          _ => PolicyAction.show,
        },
        reasons: [
          for (final r in (j['reasons'] as List?) ?? const [])
            if (r is Map) PolicyReason.fromJson(r.cast<String, dynamic>()),
        ],
        tags: ((j['tags'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
      );

  final String communityDid;
  final PolicyAction action;
  final List<PolicyReason> reasons;

  /// Every label that applies, including ones the policy only shows.
  final List<String> tags;
}

/// The Ethne calls this layer needs, so it is testable without the cdylib.
abstract class CommunityCrypto {
  /// The verified contents of a policy artifact, or null.
  Map<String, dynamic>? verifyPolicy(String bundle);

  /// The verdict for one post, as `ethne_content_policy_verdict` returns it.
  Map<String, dynamic> verdict({
    required String policyBundle,
    required String postId,
    required List<String> authorLabels,
    required List<String> labels,
    required int authorTier,
    required bool authorOperatorBound,
    required int authorPostIndexToday,
  });

  /// A moderator's signed label, as `ethne_post_label_sign` returns it.
  String signLabel({
    required String communityDid,
    required String postId,
    required List<String> labels,
    required int seq,
    required Map<String, dynamic> moderatorPriv,
    required String moderatorDid,
  });
}

/// A label bundle as it arrived, keyed so a repeat is kept once.
class HeldLabel {
  const HeldLabel({
    required this.labelId,
    required this.communityDid,
    required this.postId,
    required this.bundle,
  });

  final String labelId;
  final String communityDid;
  final String postId;
  final String bundle;
}

/// The reader's own community state.
class CommunityBook {
  /// Policies this node follows, by community DID.
  final Map<String, CommunityPolicy> followed = {};

  /// The newest verified policy HEARD for each community, followed or not, so
  /// a reader can see what a community asks before following it.
  final Map<String, CommunityPolicy> heard = {};

  /// Communities whose policy this reader has switched off for itself.
  final Set<String> disabled = {};

  final Map<String, Map<String, HeldLabel>> _labelsByPost = {};

  /// (community, author, UTC day) -> the post ids in the order received.
  final Map<String, List<String>> _postsByAuthorDay = {};

  /// Take in a verified policy. Returns true when it is NEWER than the one
  /// followed for its community — the caller then hands the newer bundle to the
  /// core, which never replaces a held policy from the wire itself.
  bool hear(CommunityPolicy p) {
    final prev = heard[p.communityDid];
    if (prev == null || p.seq > prev.seq) heard[p.communityDid] = p;
    final held = followed[p.communityDid];
    if (held != null && p.seq > held.seq) {
      followed[p.communityDid] = p;
      return true;
    }
    return false;
  }

  /// Follow the newest heard policy for [did]. Returns it, or null when none
  /// has been heard.
  CommunityPolicy? follow(String did) {
    final p = heard[did];
    if (p == null) return null;
    followed[did] = p;
    return p;
  }

  void unfollow(String did) {
    followed.remove(did);
    disabled.remove(did);
  }

  /// Keep one label bundle per [HeldLabel.labelId].
  bool addLabel(HeldLabel l) {
    final m = _labelsByPost.putIfAbsent(l.postId, () => {});
    if (m.containsKey(l.labelId)) return false;
    m[l.labelId] = l;
    return true;
  }

  /// Every label bundle held for [postId] in [communityDid], as received. The
  /// library decides which count.
  List<String> labelsFor(String communityDid, String postId) => [
        for (final l in (_labelsByPost[postId] ?? const {}).values)
          if (l.communityDid == communityDid) l.bundle,
      ];

  /// The 1-based place of [post] among its author's posts in its community on
  /// the UTC day it was made, as this reader received them. Idempotent: a post
  /// keeps the place it got first.
  int indexToday(Post post) {
    final day = DateTime.fromMillisecondsSinceEpoch((post.ts * 1000).round(),
            isUtc: true)
        .toIso8601String()
        .substring(0, 10);
    final key = '${post.community}|${post.authorHex}|$day';
    final ids = _postsByAuthorDay.putIfAbsent(key, () => []);
    final at = ids.indexOf(post.postId);
    if (at >= 0) return at + 1;
    ids.add(post.postId);
    return ids.length;
  }

  /// The policy to apply to a post made in [did], or null when this reader
  /// does not follow it or has switched it off.
  CommunityPolicy? applying(String did) =>
      disabled.contains(did) ? null : followed[did];

  Map<String, dynamic> toJson() => {
        'followed': {
          for (final e in followed.entries)
            e.key: {'bundle': e.value.bundle, 'seq': e.value.seq},
        },
        'heard': {
          for (final e in heard.entries)
            e.key: {'bundle': e.value.bundle, 'seq': e.value.seq},
        },
        'disabled': disabled.toList()..sort(),
      };

  /// Restore from [toJson]. Every bundle is RE-VERIFIED through [verify]: a
  /// file on disk is not a policy the community signed until it verifies.
  static CommunityBook fromJson(Map<String, dynamic> j,
      Map<String, dynamic>? Function(String bundle) verify) {
    final book = CommunityBook();
    CommunityPolicy? read(Object? rec) {
      if (rec is! Map || rec['bundle'] is! String) return null;
      final bundle = rec['bundle'] as String;
      final v = verify(bundle);
      return v == null ? null : CommunityPolicy.fromVerified(v, bundle);
    }

    for (final kind in ['heard', 'followed']) {
      final m = j[kind];
      if (m is! Map) continue;
      for (final e in m.entries) {
        final p = read(e.value);
        if (p == null || p.communityDid != e.key) continue;
        (kind == 'heard' ? book.heard : book.followed)[p.communityDid] = p;
      }
    }
    for (final d in (j['disabled'] as List?) ?? const []) {
      if (d is String && book.followed.containsKey(d)) book.disabled.add(d);
    }
    return book;
  }
}

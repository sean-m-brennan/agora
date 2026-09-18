// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The published member roll (Phase 3 P3.3 S9, D26): border artifact #6, the
// polity's roll signed under its ROOT key. It is what gives a polity's members a
// real anonymous channel in a compact tier that models communities and speakers
// but keeps no member roster of its own.
//
// THE TWO ANSWERS ARE KEPT APART HERE, deliberately, because they are different
// questions and collapsing them would overstate what a reader knows:
//
//   publisherProven    — the roll is signed by the polity it names and is
//                        well-formed. This is the WHOLE reach a compact tier
//                        has. A roll is the polity speaking about itself, so
//                        this says who is speaking, never whether it is true.
//   auditedAgainstLog  — the roll also matches what this node's charter log says
//                        the membership was at the roll's `as_of`. A compact
//                        tier CANNOT do this; it has no dependency on this
//                        tier's charter. A polity's own node can.
//
// `as_of` is provenance, not authority. Nothing gates on it; it only says which
// reading of the log the roll claims to be.

import 'dart:convert';

/// A minted roll and what could be established about it.
class PublishedRoll {
  const PublishedRoll({
    required this.rollJson,
    required this.publisherProven,
    this.auditedAgainstLog,
  });

  /// The `Signed<MemberRoll>` JSON, exactly as it would travel.
  final String rollJson;

  /// The publisher is the polity it names, and the roll is well-formed.
  final bool publisherProven;

  /// The roll agrees with this node's log at its `as_of`. Null when no log was
  /// available to ask — which is not the same as a failed audit.
  final bool? auditedAgainstLog;

  Map<String, dynamic>? get _payload {
    try {
      final obj = jsonDecode(rollJson);
      if (obj is Map && obj['payload'] is Map) {
        return (obj['payload'] as Map).cast<String, dynamic>();
      }
    } catch (_) {
      // an artifact we cannot read tells us nothing; the getters say so
    }
    return null;
  }

  /// The polity that published it.
  String? get communityDid => _payload?['community_did'] as String?;

  /// How many members it names. The polity itself is never among them.
  int get memberCount {
    final m = _payload?['members'];
    return m is List ? m.length : 0;
  }

  /// The instant the roll was read from the log — provenance only.
  int? get asOf {
    final v = _payload?['as_of'];
    return v is num ? v.toInt() : null;
  }
}

/// Mints a roll and reports what could be established about it. Injected in
/// tests so the surface runs with no charter log and no cdylib, the same shape
/// as the bundle verifier and the co-signature describer.
typedef RollPublisher = PublishedRoll? Function();

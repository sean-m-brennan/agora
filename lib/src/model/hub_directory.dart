// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// People nearby, found at a community's area hubs (SOCIAL_APP_PLAN Phase 4,
// §4.1 band 2). Everything here is what this reader's own node was told: its
// listings as the hubs confirmed them, the cards its lookups found (each
// already checked by the node, never on a hub's word), and the contact
// requests in flight either way. Found people are the Recognition circle: seen,
// not admitted, and no Dunbar budget is spent on them. Asking one to connect
// goes through first contact, and a yes makes a DIRECT peer, never a member of
// anyone's cohort.

import '../ffi/at_events_bindings.dart';
import '../geo/geohash.dart';

/// Someone a lookup found in an area.
class HubCard {
  const HubCard({
    required this.uuid,
    required this.area,
    required this.bucket,
    required this.name,
    required this.relay,
    required this.seenAt,
  });

  final List<int> uuid;
  final String area;

  /// Their coarse bucket inside [area] (at most five characters, ~5 km).
  final String bucket;

  /// What they list under; may be empty.
  final String name;

  /// The hub that answered.
  final String relay;
  final DateTime seenAt;

  String get uuidHex =>
      uuid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Centre to centre, from [ownBucket]; null when either is unknown.
  double? distanceKmFrom(String? ownBucket) =>
      ownBucket == null || ownBucket.isEmpty ? null : geohashDistanceKm(ownBucket, bucket);
}

/// Where a contact request stands.
enum ContactStage { asked, accepted, declined, refused, established }

/// A request this reader's app must answer: someone asks to become a contact.
class IncomingContact {
  const IncomingContact({
    required this.ref,
    required this.uuid,
    required this.nickname,
    required this.foundBy,
  });

  /// What to answer with (the request's nonce).
  final String ref;
  final List<int> uuid;
  final String nickname;

  /// Where they found us: "area:<area>" for a hub, or a handle.
  final String foundBy;

  String get uuidHex =>
      uuid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// How long a card is shown without a fresher lookup confirming it. A card
/// lives an hour at the hub; this keeps the list honest between lookups.
const Duration hubCardShownFor = Duration(minutes: 30);

class HubDirectory {
  /// Areas a hub confirmed listing us in.
  final Set<String> listed = {};

  /// The last refusal a hub gave a listing, by area ("" once listed again).
  final Map<String, String> refusals = {};

  /// area -> uuid hex -> card.
  final Map<String, Map<String, HubCard>> _cards = {};

  /// Requests to answer, by ref.
  final Map<String, IncomingContact> incoming = {};

  /// Our own requests, by the other person's uuid hex.
  final Map<String, ContactStage> outgoing = {};

  /// Community issuers whose roster the node installed.
  final Set<String> installedRosters = {};

  /// The cards found in [area], freshest first, dropping any not seen within
  /// [hubCardShownFor] of [now].
  List<HubCard> cardsIn(String area, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final held = _cards[area]?.values ?? const <HubCard>[];
    return [
      for (final c in held)
        if (at.difference(c.seenAt) <= hubCardShownFor) c
    ]..sort((a, b) => b.seenAt.compareTo(a.seenAt));
  }

  /// Every card found, in every area; one per person (the freshest).
  List<HubCard> allCards({DateTime? now}) {
    final best = <String, HubCard>{};
    for (final area in _cards.keys) {
      for (final c in cardsIn(area, now: now)) {
        final held = best[c.uuidHex];
        if (held == null || c.seenAt.isAfter(held.seenAt)) best[c.uuidHex] = c;
      }
    }
    return best.values.toList()..sort((a, b) => b.seenAt.compareTo(a.seenAt));
  }

  /// Take in one [agoraEventArea] or [agoraEventContact] event. Returns true
  /// when anything shown changed.
  bool ingest(AtRawEvent e, {DateTime? now}) {
    final at = now ?? DateTime.now();
    if (e.kind == agoraEventArea) {
      switch (e.fcKind) {
        case atAreaPublished:
          refusals.remove(e.area);
          return listed.add(e.area);
        case atAreaRefused:
          refusals[e.area] = e.fcReason;
          return true;
        case atAreaWithdrawn:
          _cards.remove(e.area);
          return listed.remove(e.area);
        case atAreaCard:
          (_cards[e.area] ??= {})[_hex(e.uuid)] = HubCard(
              uuid: e.uuid,
              area: e.area,
              bucket: e.areaBucket,
              name: e.areaName,
              relay: e.fcRelay,
              seenAt: at);
          return true;
        case atAreaDone:
          return false;
        case atRosterInstalled:
          return installedRosters.add(e.areaIssuer);
        case atRosterRemoved:
          return installedRosters.remove(e.areaIssuer);
      }
      return false;
    }
    if (e.kind != agoraEventContact) return false;
    final who = _hex(e.uuid);
    switch (e.fcKind) {
      case atDirContactRequest:
        incoming[e.fcRef] = IncomingContact(
            ref: e.fcRef, uuid: e.uuid, nickname: e.fcNickname, foundBy: e.fcHandle);
        return true;
      case atDirRequestSent:
        outgoing[who] = ContactStage.asked;
        return true;
      case atDirAccepted:
      case atDirDeclined:
        // Our own app's answer to a request we held.
        incoming.remove(e.fcRef);
        return true;
      case atFcEstablished:
        outgoing[who] = ContactStage.established;
        incoming.removeWhere((_, c) => c.uuidHex == who);
        return true;
      case atFcRefused:
      case atDirRefused:
        if (who != _zero) outgoing[who] = ContactStage.refused;
        return true;
    }
    return false;
  }

  static final String _zero = '0' * 32;

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

/// The areas, of those [hubAreas] names, that hold [ownBucket]: where this
/// reader could be listed. An area holds a bucket that starts with it.
List<String> areasHolding(String? ownBucket, Iterable<String> hubAreas) {
  if (ownBucket == null || ownBucket.isEmpty) return const [];
  final b = ownBucket.toLowerCase();
  return ({for (final a in hubAreas) if (b.startsWith(a)) a}.toList()..sort());
}

/// The bucket a card carries: our own shared bucket, cut to five characters
/// (~5 km). Nothing finer is ever sent to a hub.
String hubBucket(String ownBucket) =>
    ownBucket.length <= 5 ? ownBucket.toLowerCase() : ownBucket.substring(0, 5).toLowerCase();

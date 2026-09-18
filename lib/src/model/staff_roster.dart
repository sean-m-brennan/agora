// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The staff roll of one polity, folded for display (Phase 3 P3.3,
// SOCIAL_APP_PLAN.md §2.2). Two Ethne read helpers answer two different
// questions, and this model joins them on member DID:
//
//   affirmationState → who is on the roll, who is SEASONED (inducted, and
//                      therefore carrying deciding weight), and what a vote
//                      actually costs.
//   guardianState    → which members are machines, who each answers to, and
//                      what backs that claim.
//
// It takes the two decoded JSON MAPS rather than an EthneArchive on purpose: the
// fold is then pure and deterministic, and unit- and widget-tests exercise every
// honest state with no cdylib present.
//
// WHAT THIS MODEL IS NOT. It is a fold of what the log CLAIMS, not an
// adjudication of whether the log is sound — an append is not gated on the
// authority rules, so an invalid induction still moves `seasoned` here and is
// caught only by ethne_verify. Carry [verified] beside the readout and show it,
// the same division of labour P3.1 shipped when it put verify_full next to the
// page read.

/// One row of the roll: a member, whether it decides, and — when it is a machine
/// — who answers for it and what grounds that.
class StaffMember {
  const StaffMember({
    required this.did,
    required this.inducted,
    this.lastAffirmedAt,
    this.isMachine = false,
    this.guardianDid,
    this.guarded = false,
    this.backed = false,
    this.evidence = '',
    this.reason,
    this.observer,
    this.observedAt,
    this.attestedAt,
    this.attendanceStale = false,
  });

  /// The member's decentralized identifier.
  final String did;

  /// Inducted through the five-movement rite, and so counted in every majority.
  /// An admitted-but-uninducted member is on the roll and carries ZERO deciding
  /// weight — a real state, not a loading state.
  final bool inducted;

  /// When this member last affirmed, or null if never.
  final int? lastAffirmedAt;

  /// The substrate reported this member as derived (a machine) rather than human.
  final bool isMachine;

  /// The human who answers for this machine, or null when it has none.
  final String? guardianDid;

  /// Whether a guardian edge exists at all. An unguarded machine is an honest
  /// chartered state rather than a missing value, and it is NOT an error: a
  /// release clears the edge and keeps the designation, because a machine does
  /// not become human by losing its human.
  final bool guarded;

  /// Whether the edge is GROUNDED by an observation taken from outside the roll.
  /// This is a GRADE, not validity: an edge can be perfectly valid and unbacked,
  /// and must be shown as what it is. See [reason].
  final bool backed;

  /// `'observed'`, `'unbacked'`, `'none'`, or empty for a human member.
  final String evidence;

  /// Why the edge is not backed — the stated override, or that the observer sat
  /// inside the roll and so cannot ground it. Present whenever [backed] is false
  /// and there is something to say.
  final String? reason;

  /// Who signed the observation, when one was cited.
  final String? observer;

  /// When the observation was taken.
  final int? observedAt;

  /// When a human was last confirmed at this machine's console. A STAMP, not a
  /// verdict. Null or non-positive means no stamp at all, which per
  /// operator-attended.md is the same answer as "asked and nobody was there" —
  /// and is a different fact from an aging one.
  final int? attestedAt;

  /// The stamp exists and has aged past the caller's threshold. May warn. Must
  /// not escalate on its own: a node bound to a guardian with nobody at the
  /// keyboard for a week is a normal state.
  final bool attendanceStale;

  /// Whether a usable attendance stamp is present at all. Distinguishes "aging"
  /// from "never reported", which the two signals must never conflate.
  bool get hasAttendanceStamp => attestedAt != null && attestedAt! > 0;

  /// A machine with nobody answering for it.
  bool get isUnguardedMachine => isMachine && !guarded;
}

/// The whole roll, plus what a vote costs and what the machines in it answer to.
class StaffRoster {
  const StaffRoster({
    required this.polityDid,
    required this.roll,
    required this.seasoned,
    required this.admitNeed,
    required this.expelNeed,
    required this.canContract,
    required this.derived,
    required this.machineMajority,
    required this.unguarded,
    required this.members,
    this.verified,
  });

  /// The polity, when affirmationState named one. guardianState does not carry a
  /// polity DID, which is why the two are joined on member rather than on polity.
  final String? polityDid;

  /// Everyone on the roll.
  final int roll;

  /// Those inducted, which is the only count majorities are taken over (D29).
  final int seasoned;

  /// Signatures an admission needs: a majority of [seasoned].
  final int admitNeed;

  /// Signatures an expulsion needs: majority plus one, with the target barred
  /// from deciding its own removal.
  final int expelNeed;

  /// Whether the polity may shrink at all. False below the contraction floor,
  /// where a departure would leave a body that cannot govern itself.
  final bool canContract;

  /// How many members the substrate reported as machines.
  final int derived;

  /// Whether machines are a majority — read over the WHOLE roll rather than the
  /// inducted part of it, because it asks what the polity is made of rather than
  /// who decides in it.
  final bool machineMajority;

  /// Machines with no guardian edge.
  final List<String> unguarded;

  /// The roll in the order the log gave it. Deliberately not re-sorted: any
  /// ranking here would be this app editorializing about a polity's own record.
  final List<StaffMember> members;

  /// The result of ethne_verify beside the fold, or null when it was not run.
  final bool? verified;

  /// An expulsion bars its target from deciding, so the deciders must come from
  /// the OTHER seasoned members. Where that is impossible the bar is unreachable
  /// however many people agree — at four seasoned, an expulsion needs four
  /// deciders drawn from the three eligible. Say so rather than offering a vote
  /// that cannot close.
  bool get expelReachable => expelNeed <= seasoned - 1;

  /// Eligible deciders for an expulsion: everyone seasoned except the target.
  int get expelEligible => seasoned > 0 ? seasoned - 1 : 0;

  /// Machines nobody answers for.
  bool get anyUnguardedMachine => unguarded.isNotEmpty;

  /// Edges that are valid but not grounded from outside the roll.
  Iterable<StaffMember> get unbackedEdges =>
      members.where((m) => m.isMachine && m.guarded && !m.backed);

  /// Machines whose attendance stamp has aged past the threshold.
  Iterable<StaffMember> get staleAttendance =>
      members.where((m) => m.attendanceStale);

  /// Members on the roll carrying no deciding weight yet.
  Iterable<StaffMember> get uninducted => members.where((m) => !m.inducted);

  /// Fold `affirmationState` and `guardianState` into one roll.
  ///
  /// [staleAfterSeconds] is the caller's judgment about the attendance stamp and
  /// nothing more; the stamp itself is carried through unreduced.
  static StaffRoster from({
    required Map<String, dynamic> affirmation,
    required Map<String, dynamic> guardian,
    required int nowEpochSeconds,
    int staleAfterSeconds = 86400,
    bool? verified,
  }) {
    // Index the guardian edges by member so the join is by DID, not by position.
    final edges = <String, Map<String, dynamic>>{};
    final rawEdges = guardian['edges'];
    if (rawEdges is List) {
      for (final e in rawEdges) {
        if (e is Map) {
          final m = e['member'];
          if (m is String) edges[m] = e.cast<String, dynamic>();
        }
      }
    }

    final unguarded = <String>[];
    final rawUnguarded = guardian['unguarded'];
    if (rawUnguarded is List) {
      for (final u in rawUnguarded) {
        if (u is String) unguarded.add(u);
      }
    }

    final members = <StaffMember>[];
    final rawMembers = affirmation['members'];
    if (rawMembers is List) {
      for (final raw in rawMembers) {
        if (raw is! Map) continue;
        final did = raw['did'];
        if (did is! String) continue;
        final edge = edges[did];

        int? stamp;
        final at = edge?['attested_at'];
        if (at is num) stamp = at.toInt();

        // A stamp that is absent or non-positive is not stale — it is no stamp.
        // Ageing and never-reported are different facts and are kept apart here
        // so no widget can conflate them.
        final hasStamp = stamp != null && stamp > 0;
        final stale =
            hasStamp && (nowEpochSeconds - stamp) > staleAfterSeconds;

        members.add(StaffMember(
          did: did,
          inducted: raw['inducted'] == true,
          lastAffirmedAt: _asInt(raw['last_affirmed_at']),
          isMachine: edge != null,
          guardianDid: edge?['guardian'] as String?,
          guarded: edge?['guarded'] == true,
          backed: edge?['backed'] == true,
          evidence: (edge?['evidence'] as String?) ?? '',
          reason: edge?['reason'] as String?,
          observer: edge?['observer'] as String?,
          observedAt: _asInt(edge?['observed_at']),
          attestedAt: stamp,
          attendanceStale: stale,
        ));
      }
    }

    return StaffRoster(
      polityDid: affirmation['polity_did'] as String?,
      roll: _asInt(affirmation['roll']) ?? members.length,
      seasoned: _asInt(affirmation['seasoned']) ?? 0,
      admitNeed: _asInt(affirmation['admit_need']) ?? 0,
      expelNeed: _asInt(affirmation['expel_need']) ?? 0,
      canContract: affirmation['can_contract'] == true,
      derived: _asInt(guardian['derived']) ?? edges.length,
      machineMajority: guardian['machine_majority'] == true,
      unguarded: unguarded,
      members: members,
      verified: verified,
    );
  }

  static int? _asInt(Object? v) => v is num ? v.toInt() : null;
}

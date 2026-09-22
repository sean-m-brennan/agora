// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Moderation, the app's half (Phase 4 P4.1): why the operator reported
// someone, and the advisory count that greys the Report action out before the
// core would refuse it.
//
// The core is the authority on every one of these. A block lives in the core
// (etc/at/social.cfg.json) and comes back on the peer event; a report's caps
// are enforced there, on both sides of the wire. What lives HERE is what the
// core deliberately never sees: the REASON. It stays on this device because on
// the wire it would turn a score into a published accusation.
//
// Pure and deterministic given its inputs, so it is unit tested directly.

/// Why the operator reported someone. Kept on this device only.
///
/// The [code]s are FROZEN and append-only: they are what the local store
/// writes, so renumbering one would silently relabel every report already on
/// disk. Add a reason by appending a new value with the next code.
enum ReportReason {
  harassment(1, 'Harassment or threats'),
  spam(2, 'Spam or unwanted contact'),
  deception(3, 'Impersonation or deception'),
  unsafe(4, 'Made me feel unsafe'),
  other(5, 'Something else');

  const ReportReason(this.code, this.label);

  /// The stored, frozen identifier.
  final int code;

  /// What the report sheet shows.
  final String label;

  /// The reason for a stored [code], or [other] for one this build does not
  /// know (a newer build wrote it) — never a crash on a file from the future.
  static ReportReason fromCode(int code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return other;
  }
}

/// Reports per peer per day, mirroring the core's AT_SOCIAL_REPORT_DAILY_CAP.
/// ADVISORY: the core's own check is the authority, and its caps also include
/// a shared daily budget this app cannot see.
const int reportDailyCap = 1;

/// Seconds per day — the same UTC day boundary the core rolls its caps over.
const int _daySeconds = 86400;

/// The UTC day number for [epochSeconds], as the core computes it.
int dayOf(double epochSeconds) => epochSeconds ~/ _daySeconds;

/// One report the operator made, as this device remembers it.
class ReportRecord {
  const ReportRecord({required this.at, required this.reason});

  /// When it was sent (epoch seconds).
  final double at;
  final ReportReason reason;

  Map<String, dynamic> toJson() => {'at': at, 'reason': reason.code};

  /// Null for a malformed entry, which the store then drops rather than
  /// guessing at.
  static ReportRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = j['at'];
    final reason = j['reason'];
    if (at is! num || reason is! int) return null;
    return ReportRecord(
        at: at.toDouble(), reason: ReportReason.fromCode(reason));
  }
}

/// This device's moderation memory: the last report made about each peer,
/// keyed by uuid hex. Only the LAST is kept — enough to show the operator what
/// they said and to apply the daily cap, and no more than that about anyone.
class ModerationState {
  ModerationState({Map<String, ReportRecord>? reports})
      : reports = reports ?? <String, ReportRecord>{};

  final Map<String, ReportRecord> reports;

  /// The last report this device made about [peerHex], or null.
  ReportRecord? lastReportOf(String peerHex) => reports[peerHex];

  /// How many more reports of [peerHex] the core would accept today, as far
  /// as this device knows (0 or [reportDailyCap]).
  int reportsLeftToday(String peerHex, double nowEpochSeconds) {
    final last = reports[peerHex];
    if (last == null || dayOf(last.at) != dayOf(nowEpochSeconds)) {
      return reportDailyCap;
    }
    return 0;
  }

  /// True when the Report action should be offered for [peerHex] now.
  bool canReport(String peerHex, double nowEpochSeconds) =>
      reportsLeftToday(peerHex, nowEpochSeconds) > 0;

  /// Remember a report the core accepted onto its queue.
  void recordReport(
      String peerHex, ReportReason reason, double nowEpochSeconds) {
    reports[peerHex] = ReportRecord(at: nowEpochSeconds, reason: reason);
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'reports': {for (final e in reports.entries) e.key: e.value.toJson()},
      };

  /// Tolerant of anything: an unknown version or a malformed entry yields an
  /// empty or partial state, never a throw.
  factory ModerationState.fromJson(Map<String, dynamic> j) {
    final out = <String, ReportRecord>{};
    final raw = j['reports'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final rec = ReportRecord.fromJson(e.value);
        if (e.key is String && rec != null) out[e.key as String] = rec;
      }
    }
    return ModerationState(reports: out);
  }
}

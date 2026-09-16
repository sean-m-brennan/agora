// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Per-user, persisted settings for the tie-strength kernel and the attention
// budget (Phase 2, SOCIAL_APP_PLAN.md §3.3). The tie-strength weights and the
// budget parameters are tunable per user; a durable per-peer last-interaction
// timestamp lets the recency term — and therefore the budget cost of a tie —
// survive an app restart (in-memory `AgoraPeer.lastInteractionAt` alone would
// reset every launch, spuriously letting every tended tie "go cold").
//
// Stored as a small JSON file under the daemon root (alongside the identity
// config the app already reads). All I/O is best-effort: any failure falls back
// to defaults and never throws into the app — a missing or corrupt file simply
// means "use defaults", exactly as a first launch would.

import 'dart:convert';
import 'dart:io';

import 'attention_budget.dart';
import 'tie_strength.dart';

/// The persisted settings bundle: kernel weights, budget params, and the durable
/// per-peer last-interaction map (peer uuid hex → epoch seconds).
class TieSettings {
  TieSettings({
    TieStrengthWeights? weights,
    AttentionBudgetParams? budget,
    Map<String, double>? lastInteraction,
  })  : weights = weights ?? TieStrengthWeights.defaults,
        budget = budget ?? AttentionBudgetParams.defaults,
        lastInteraction = lastInteraction ?? <String, double>{};

  TieStrengthWeights weights;
  AttentionBudgetParams budget;
  final Map<String, double> lastInteraction;

  Map<String, dynamic> toJson() => {
        'weights': weightsToJson(weights),
        'budget': budgetToJson(budget),
        'lastInteraction': lastInteraction,
      };

  factory TieSettings.fromJson(Map<String, dynamic> j) {
    final li = <String, double>{};
    final raw = j['lastInteraction'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (k is String && v is num) li[k] = v.toDouble();
      });
    }
    return TieSettings(
      weights: j['weights'] is Map
          ? weightsFromJson((j['weights'] as Map).cast<String, dynamic>())
          : null,
      budget: j['budget'] is Map
          ? budgetFromJson((j['budget'] as Map).cast<String, dynamic>())
          : null,
      lastInteraction: li,
    );
  }
}

/// A best-effort JSON-file store for [TieSettings]. Construct with the target
/// file, [load] once at startup, mutate through the helpers, and [save] (calls
/// are debounced by the caller). Every method swallows I/O errors.
class TieSettingsStore {
  TieSettingsStore(this.file);

  final File file;
  TieSettings settings = TieSettings();

  /// Load settings from disk. On any error (missing, unreadable, malformed),
  /// leaves [settings] at defaults. Returns this for chaining.
  Future<TieSettingsStore> load() async {
    try {
      if (await file.exists()) {
        final obj = jsonDecode(await file.readAsString());
        if (obj is Map<String, dynamic>) {
          settings = TieSettings.fromJson(obj);
        }
      }
    } catch (_) {
      // keep defaults
    }
    return this;
  }

  /// Persist the current settings. Best-effort; never throws.
  Future<void> save() async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(settings.toJson()));
    } catch (_) {
      // best-effort
    }
  }

  /// Record an interaction with the peer at [nowEpochSeconds] (monotone — never
  /// moves a timestamp backwards).
  void recordInteraction(String peerUuidHex, double nowEpochSeconds) {
    final prev = settings.lastInteraction[peerUuidHex] ?? 0;
    if (nowEpochSeconds > prev) {
      settings.lastInteraction[peerUuidHex] = nowEpochSeconds;
    }
  }

  /// The durable last-interaction time for the peer, or null if none recorded.
  double? lastInteractionFor(String peerUuidHex) =>
      settings.lastInteraction[peerUuidHex];
}

// --- serialization helpers (kept out of the pure model files) ----------------

Map<String, dynamic> weightsToJson(TieStrengthWeights w) => {
      'wTier': w.wTier,
      'wRecency': w.wRecency,
      'wProximity': w.wProximity,
      'localityScaleKm': w.localityScaleKm,
      'rttScaleMs': w.rttScaleMs,
      'recencyTauSeconds': w.recencyTauSeconds,
    };

TieStrengthWeights weightsFromJson(Map<String, dynamic> j) {
  const d = TieStrengthWeights.defaults;
  double n(String k, double fallback) {
    final v = j[k];
    return v is num ? v.toDouble() : fallback;
  }

  return TieStrengthWeights(
    wTier: n('wTier', d.wTier),
    wRecency: n('wRecency', d.wRecency),
    wProximity: n('wProximity', d.wProximity),
    localityScaleKm: n('localityScaleKm', d.localityScaleKm),
    rttScaleMs: n('rttScaleMs', d.rttScaleMs),
    recencyTauSeconds: n('recencyTauSeconds', d.recencyTauSeconds),
  );
}

Map<String, dynamic> budgetToJson(AttentionBudgetParams b) => {
      'budget': b.budget,
      'baseCost': b.baseCost,
      'proximityFloor': b.proximityFloor,
      'recencyFloor': b.recencyFloor,
      'strongTieMinStrength': b.strongTieMinStrength,
    };

AttentionBudgetParams budgetFromJson(Map<String, dynamic> j) {
  const d = AttentionBudgetParams.defaults;
  double n(String k, double fallback) {
    final v = j[k];
    return v is num ? v.toDouble() : fallback;
  }

  return AttentionBudgetParams(
    budget: n('budget', d.budget),
    baseCost: n('baseCost', d.baseCost),
    proximityFloor: n('proximityFloor', d.proximityFloor),
    recencyFloor: n('recencyFloor', d.recencyFloor),
    strongTieMinStrength: n('strongTieMinStrength', d.strongTieMinStrength),
  );
}

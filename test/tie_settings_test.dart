// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Unit tests for the persisted tie/budget settings store (Phase 2, §3.3).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/model/attention_budget.dart';
import 'package:agora/src/model/tie_settings.dart';
import 'package:agora/src/model/tie_strength.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('agora_settings_test');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  File settingsFile() => File('${tmp.path}/etc/at/agora.settings.json');

  test('missing file loads defaults, never throws', () async {
    final store = await TieSettingsStore(settingsFile()).load();
    expect(store.settings.weights.wTier, TieStrengthWeights.defaults.wTier);
    expect(store.settings.budget.budget, AttentionBudgetParams.defaults.budget);
    expect(store.lastInteractionFor('abcd'), isNull);
  });

  test('round-trips weights, budget params, and interactions', () async {
    final a = TieSettingsStore(settingsFile());
    a.settings.weights = const TieStrengthWeights(wTier: 0.5, wRecency: 0.25, wProximity: 0.25);
    a.settings.budget = AttentionBudgetParams.defaults.copyWith(budget: 200.0, baseCost: 2.0);
    a.recordInteraction('deadbeef', 111.0);
    await a.save();

    final b = await TieSettingsStore(settingsFile()).load();
    expect(b.settings.weights.wTier, closeTo(0.5, 1e-9));
    expect(b.settings.budget.budget, closeTo(200.0, 1e-9));
    expect(b.settings.budget.baseCost, closeTo(2.0, 1e-9));
    expect(b.lastInteractionFor('deadbeef'), closeTo(111.0, 1e-9));
  });

  test('recordInteraction is monotone (never moves backwards)', () {
    final s = TieSettingsStore(settingsFile());
    s.recordInteraction('p', 100.0);
    s.recordInteraction('p', 50.0); // older — ignored
    expect(s.lastInteractionFor('p'), closeTo(100.0, 1e-9));
    s.recordInteraction('p', 150.0); // newer — kept
    expect(s.lastInteractionFor('p'), closeTo(150.0, 1e-9));
  });

  test('corrupt file falls back to defaults', () async {
    final f = settingsFile();
    await f.parent.create(recursive: true);
    await f.writeAsString('{not valid json');
    final store = await TieSettingsStore(f).load();
    expect(store.settings.budget.budget, AttentionBudgetParams.defaults.budget);
  });
}

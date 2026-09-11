// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Unit tests for the four audience tiers (Increment 4, SOCIAL_APP_PLAN.md §3.4)
// and their mapping to/from trust tiers.

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/model/tie_strength.dart';

void main() {
  group('audienceForTier', () {
    test('tier 0 ⇒ public', () {
      expect(audienceForTier(0), PostAudience.public);
    });
    test('tier 1 ⇒ acquaintance', () {
      expect(audienceForTier(1), PostAudience.acquaintance);
    });
    test('tier 2 ⇒ friend', () {
      expect(audienceForTier(2), PostAudience.friend);
    });
    test('tiers 3 and 4 ⇒ close (both the highest-trust band)', () {
      expect(audienceForTier(3), PostAudience.close);
      expect(audienceForTier(4), PostAudience.close);
    });
  });

  group('minTierForAudience is the inverse gate', () {
    test('each audience names the minimum tier a reader must hold', () {
      expect(minTierForAudience(PostAudience.public), 0);
      expect(minTierForAudience(PostAudience.acquaintance), 1);
      expect(minTierForAudience(PostAudience.friend), 2);
      expect(minTierForAudience(PostAudience.close), 3);
    });

    test('a reader at or above the audience floor is admitted', () {
      // A tier-3 reader meets every audience up to close; a tier-1 reader meets
      // only public + acquaintance.
      for (final a in PostAudience.values) {
        expect(3 >= minTierForAudience(a), isTrue, reason: 'tier 3 meets $a');
      }
      expect(1 >= minTierForAudience(PostAudience.friend), isFalse);
    });
  });

  group('score → tier → audience end to end', () {
    test('reputation floors land in the expected audience band', () {
      PostAudience bandFor(double score, bool rated) =>
          audienceForTier(trustTierForScore(score, rated));
      expect(bandFor(0.30, true), PostAudience.public); // tier 0
      expect(bandFor(0.30, false), PostAudience.public); // unrated
      expect(bandFor(0.55, true), PostAudience.acquaintance); // tier 1
      expect(bandFor(0.70, true), PostAudience.friend); // tier 2
      expect(bandFor(0.85, true), PostAudience.close); // tier 3
      expect(bandFor(0.95, true), PostAudience.close); // tier 4
    });
  });

  group('audienceLabel', () {
    test('labels are stable and lowercase', () {
      expect(audienceLabel(PostAudience.public), 'public');
      expect(audienceLabel(PostAudience.acquaintance), 'acquaintance');
      expect(audienceLabel(PostAudience.friend), 'friend');
      expect(audienceLabel(PostAudience.close), 'close');
    });
  });
}

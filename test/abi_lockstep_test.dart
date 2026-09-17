// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// ABI lockstep for `agora_event_t` (Phase 3 P3.3, S5).
//
// Four mirrors of one C struct have to agree byte for byte: the struct itself
// (native/at_agora_shim.h), the ctypes `Ev` in test/cohort/two_node_cohort.sh
// and test/cohort/business_cohort.sh, and the dart:ffi `AgoraEvent` the app
// actually decodes events with. Three of the four already asserted their own
// size. The Dart one — the mirror the running app reads every event through —
// asserted nothing, so a drift there would surface as garbage in the UI rather
// than as a failing build.
//
// This closes that. It needs no native library: dart:ffi computes the layout
// from the annotations alone, which is exactly the thing being checked.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';

void main() {
  test('AgoraEvent matches sizeof(agora_event_t)', () {
    // Grew 8024 -> 11288 with the P3.2 business tail, and 11288 -> 17872 with
    // the P3.3 co-signing tail. When this fails, the C struct moved: update
    // at_agora_shim.c's _Static_assert, both cohort ctypes Ev asserts, and this
    // one TOGETHER, and check that only the tail grew.
    expect(sizeOf<AgoraEvent>(), 17872,
        reason: 'agora_event_t drift — poll() would misread every field '
            'past the drift point');
  });

  test('appending the P3.3 tail left the earlier field offsets alone', () {
    // The append-only discipline is what lets a consumer built against an older
    // header keep decoding what it already understood — so pin it rather than
    // trust it. dart:ffi exposes no offsetOf, so write a sentinel into the raw
    // bytes at the offset the C compiler reports and read it back through the
    // Dart field: if the field moved, it reads nothing.
    const businessBundleOffset = 8208; // unchanged by P3.3
    const cosignBytesOffset = 11720;
    final mem = calloc<Uint8>(sizeOf<AgoraEvent>());
    try {
      mem[businessBundleOffset] = 0x41; // 'A'
      mem[businessBundleOffset + 1] = 0x00;
      mem[cosignBytesOffset] = 0x62; // 'b'
      mem[cosignBytesOffset + 1] = 0x00;
      final ev = mem.cast<AgoraEvent>().ref;
      expect(ev.businessBundle[0], 0x41,
          reason: 'business_bundle moved — the P3.3 tail was not appended');
      expect(ev.cosignBytes[0], 0x62,
          reason: 'cosign_bytes is not where the C struct puts it');
    } finally {
      calloc.free(mem);
    }
  });

  test('the co-signing bounds match the C header', () {
    // These are spelled in five places (cosign.h, msg_types.h, app_events.h,
    // at_agora_shim.h, here) plus COSIGN_BYTES_HEX_MAX in ethne_ffi, and the C
    // side _Static_asserts its four against each other. This pins the Dart copy.
    expect(agoraCosignBytesMax, 6144);
    expect(agoraCosignDidMax, 95);
    expect(agoraCosignCidMax, 67);
    expect(agoraCosignSigMax, 128);
    expect(agoraCosignTokenMax, 15);
  });

  test('event kinds are append-only', () {
    // Kinds are frozen: a consumer built against an older header must keep
    // decoding what it already understood, so new kinds only ever get appended.
    expect(agoraEventBusinessAd, 12);
    expect(agoraEventCosignRequest, 13);
    expect(agoraEventCosignSignature, 14);
  });
}

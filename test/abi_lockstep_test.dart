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
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:agora/src/ffi/at_events_bindings.dart';
import 'package:agora/src/model/file_transfer.dart';

void main() {
  // The struct can be byte-perfect and the events still never arrive. In
  // agora_events_poll, `w` is the RETURN VALUE, and a case that fills its event
  // but forgets `w++` does not fail loudly: it converts the event correctly and
  // then throws it away — the next event overwrites the slot, and a batch made
  // only of such events polls as 0, which every caller reads as "queue empty".
  //
  // Both co-signing cases shipped exactly that way and it cost FIVE live cohort
  // runs to find: the signer's daemon logged "co-signing ask ... from peer" and
  // its app saw nothing, so every hop looked healthy from both ends. Nothing in
  // the ABI could catch it, because nothing about the ABI was wrong.
  //
  // Source-level on purpose: it needs no native build, so it runs in the same
  // suite as the layout checks above rather than only where a daemon exists.
  test('every agora_events_poll case counts its event (w++)', () {
    final src = File('native/at_agora_shim.c').readAsStringSync();
    final start = src.indexOf('int agora_events_poll(');
    expect(start, isNot(-1), reason: 'agora_events_poll not found in the shim');
    final end = src.indexOf('\n}', start);
    expect(end, isNot(-1), reason: 'could not find the end of agora_events_poll');
    final body = src.substring(start, end);

    // Each `case AT_APP_EVENT_x:` runs to its own `break;`.
    final cases = RegExp(r'case\s+(AT_APP_EVENT_\w+)\s*:')
        .allMatches(body)
        .toList();
    expect(cases.length, greaterThan(10),
        reason: 'the switch was not parsed — this guard would pass vacuously');

    final dropped = <String>[];
    for (var i = 0; i < cases.length; i++) {
      final from = cases[i].end;
      final to = i + 1 < cases.length ? cases[i + 1].start : body.length;
      final block = body.substring(from, to);
      final brk = block.indexOf('break;');
      // A case that falls through to the next one has no break of its own; the
      // block that DOES break is the one that must count.
      if (brk == -1) continue;
      if (!block.substring(0, brk).contains('w++')) {
        dropped.add(cases[i].group(1)!);
      }
    }
    expect(dropped, isEmpty,
        reason: 'these agora_events_poll cases convert an event and then drop '
            'it by never advancing w: ${dropped.join(", ")} — the app polls '
            'them as an empty queue');
  });

  test('AgoraEvent matches sizeof(agora_event_t)', () {
    // Grew 8024 -> 11288 with the P3.2 business tail, 11288 -> 17872 with the
    // P3.3 co-signing tail, 17872 -> 22152 with the P3.4 business-post tail,
    // 22152 -> 22168 with the P4.1 moderation tail, 22168 -> 28600 with the
    // Phase 4 communities tail, 28600 -> 29200 with the proximity-hub tail, and
    // 29200 -> 41296 with the multi-device address-book / backup tail, and
    // 41296 -> 45752 with the DM file-sharing tail. When this fails, the C
    // struct moved: update at_agora_shim.c's _Static_assert, ALL ELEVEN cohort
    // ctypes Ev asserts, and this one TOGETHER, and check that only the tail
    // grew.
    expect(sizeOf<AgoraEvent>(), 45752,
        reason: 'agora_event_t drift — poll() would misread every field '
            'past the drift point');
  });

  test('appending each tail left the earlier field offsets alone', () {
    // The append-only discipline is what lets a consumer built against an older
    // header keep decoding what it already understood — so pin it rather than
    // trust it. dart:ffi exposes no offsetOf, so write a sentinel into the raw
    // bytes at the offset the C compiler reports and read it back through the
    // Dart field: if the field moved, it reads nothing.
    const businessBundleOffset = 8208; // unchanged by P3.3 and P3.4
    const cosignBytesOffset = 11720; // unchanged by P3.4
    const businessPostBundleOffset = 18052; // unchanged by P4.1
    const blockedOffset = 22149; // P4.1, measured from the C compiler
    const postCommunityOffset = 22168; // Phase 4 communities, measured
    const labelBundleOffset = 27060; // Phase 4 communities, measured
    const areaNameOffset = 29054; // proximity hubs, measured
    const fcCountOffset = 29192; // proximity hubs, measured
    const backupRemovedOffset = 41292; // multi-device, measured
    const fileStateOffset = 41320; // DM file sharing, measured
    const filePathOffset = 41649; // DM file sharing, measured
    final mem = calloc<Uint8>(sizeOf<AgoraEvent>());
    try {
      mem[businessBundleOffset] = 0x41; // 'A'
      mem[businessBundleOffset + 1] = 0x00;
      mem[cosignBytesOffset] = 0x62; // 'b'
      mem[cosignBytesOffset + 1] = 0x00;
      mem[businessPostBundleOffset] = 0x63; // 'c'
      mem[businessPostBundleOffset + 1] = 0x00;
      mem[blockedOffset] = 0x01;
      mem[postCommunityOffset] = 0x64; // 'd'
      mem[postCommunityOffset + 1] = 0x00;
      mem[labelBundleOffset] = 0x65; // 'e'
      mem[labelBundleOffset + 1] = 0x00;
      mem[areaNameOffset] = 0x66; // 'f'
      mem[areaNameOffset + 1] = 0x00;
      mem[fcCountOffset] = 0x07;
      mem[backupRemovedOffset] = 0x09;
      mem[fileStateOffset] = 0x05;
      mem[filePathOffset] = 0x67; // 'g'
      mem[filePathOffset + 1] = 0x00;
      final ev = mem.cast<AgoraEvent>().ref;
      expect(ev.businessBundle[0], 0x41,
          reason: 'business_bundle moved — a later tail was not appended');
      expect(ev.cosignBytes[0], 0x62,
          reason: 'cosign_bytes is not where the C struct puts it');
      expect(ev.businessPostBundle[0], 0x63,
          reason: 'business_post_bundle is not where the C struct puts it');
      expect(ev.blocked, 0x01,
          reason: 'blocked is not where the C struct puts it');
      expect(ev.postCommunity[0], 0x64,
          reason: 'post_community is not where the C struct puts it');
      expect(ev.labelBundle[0], 0x65,
          reason: 'label_bundle is not where the C struct puts it');
      expect(ev.areaName[0], 0x66,
          reason: 'area_name is not where the C struct puts it');
      expect(ev.fcCount, 7, reason: 'fc_count is not where the C struct puts it');
      expect(ev.backupRemoved, 9,
          reason: 'backup_removed moved — the file tail was not appended');
      expect(ev.fileState, 5,
          reason: 'file_state is not where the C struct puts it');
      expect(ev.filePath[0], 0x67,
          reason: 'file_path is not where the C struct puts it');
    } finally {
      calloc.free(mem);
    }
  });

  test('a non-reputation event never reports a standing ceiling', () {
    // THE MOST LIKELY DEFECT IN THE P4.1 CHANGE, pinned rather than trusted.
    // The shim memsets every flattened event and writes rep_ceiling only on
    // the reputation case, so on any other kind the raw field is 0.0 — which
    // reads as "floored at zero", the strictest possible bound, rather than
    // "unbounded". The decoder must substitute the sentinel instead of passing
    // the zero through.
    //
    // Asserted through the DECODER's contract rather than the raw struct,
    // because the raw zero is correct and it is the interpretation that must
    // not be.
    expect(agoraNoCeiling, lessThan(0.0),
        reason: 'the no-ceiling sentinel must be negative, or an unbounded '
            'peer reads as bounded at that value');
    final raw = AtRawEvent(
      kind: agoraEventPost,
      uuid: <int>[],
      signingPubkey: <int>[],
      rank: 0,
      operatorBound: false,
      operatorAttestedAt: 0,
      operatorPubkey: <int>[],
      repScore: 0,
      repRated: false,
      rttMs: 0,
    );
    expect(raw.repCeiling, agoraNoCeiling,
        reason: 'a decoded event that carries no reputation must report NO '
            'ceiling, never 0.0');
  });

  test('the business-post bounds match the C header', () {
    // Spelled in business_post.h, social_msg_types.h, at_agora.h, at_agora_shim.h
    // and here, with the C side _Static_asserting its four against each other.
    // The bundle bound is MEASURED (worst case 3550 of 4096, printed by
    // ethne_ffi's the_worst_case_post_bundle_fits_the_wire_bound); widen the
    // Ethne body clamp and that test fails before this one does.
    expect(agoraBusinessPostBundleMax, 4096);
    expect(agoraBusinessPostIdMax, 64);
  });

  test('the co-signing bounds match the C header', () {
    // These are spelled in five places (cosign.h, social_msg_types.h, at_agora.h,
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
    expect(agoraEventBusinessPost, 15);
    expect(agoraEventArea, 18);
    expect(agoraEventContact, 19);
    expect(agoraEventBackup, 20);
    expect(agoraEventFile, 21);
  });

  test('the file-sharing bounds and states match the C header', () {
    // at_agora.h AT_APP_FILE_*_LEN, which the shim _Static_asserts its copies
    // against; the states are AT_APP_FILE_* and FileTransferState's indexes.
    expect(agoraFileIdMax, 32);
    expect(agoraFileNameMax, 255);
    expect(agoraFilePathMax, 4095);
    expect(agoraFileReasonMax, 31);
    expect([agoraFileOffered, agoraFileAccepted, agoraFileDone,
            agoraFileDeclined, agoraFileCancelled, agoraFileFailed,
            agoraFileTooLarge],
        [0, 1, 2, 3, 4, 5, 6]);
    expect(FileTransferState.values.map((s) => s.index),
        [0, 1, 2, 3, 4, 5, 6]);
    expect(FileTransferState.fromWire(agoraFileTooLarge),
        FileTransferState.tooLarge);
  });

  test('the address-book and backup bounds and kinds match the C header', () {
    // at_first_contact.h: AT_FC_BLOB_LEN 7680, AT_FC_SAFETY_NUMBER_LEN 72,
    // AT_FC_PATH_LEN 4096, AT_FC_PASSPHRASE_LEN 32 (each a NUL past these);
    // the shim _Static_asserts its copies against them.
    expect(agoraFcBlobMax, 7679);
    expect(agoraFcSafetyNumberMax, 71);
    expect(agoraBackupPathMax, 4095);
    expect(agoraBackupPassphraseMax, 31);
    expect([atFcInvitation, atFcContact, atFcContactsDone, atFcSafetyNumber,
            atFcVerified, atFcRemoved],
        [1000, 1004, 1005, 1006, 1007, 1008]);
    expect([atFcDeviceLinked, atFcSiblingPaired, atFcSibling, atFcSiblingsDone,
            atFcSiblingRemoved],
        [1018, 1019, 1020, 1021, 1022]);
    expect([atBackupWritten, atBackupRestored, atBackupRefused],
        [1031, 1032, 1033]);
    expect(atFcReasonNotSibling, 10);
    expect([atFcOriginLocal, atFcOriginSibling, atFcOriginBackup], [0, 1, 2]);
  });
}

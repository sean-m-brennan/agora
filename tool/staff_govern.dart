// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The KEEPER's half of the live staff cohort (test/cohort/staff_cohort.sh): the
// Ethne acts that need the charter log. Every subcommand reads and writes the
// keeper's own `agora.polity.json`, so the log advances across invocations the
// way it would on a running node.
//
// WHAT IS AND IS NOT A WIRE ACT. Only the co-signature exchange crosses the
// network. `pend` exports the bytes a decider must sign and `assemble` applies
// the signatures that came back — the wire sits between those two, and the
// cohort script is what drives it. Everything else here (the rite, a departure,
// publishing the roll) is a local act on the log, and pretending otherwise would
// make the cohort look like it tests more than it does.
//
// The RITE is deliberately not a wire act either. Induction is a ceremony with
// attending witnesses, held where the log is and with the member present, so
// this tool takes the member's own key directory rather than a DID.
//
//   dart run tool/staff_govern.dart state        <keeper-dir>
//   dart run tool/staff_govern.dart pend         <keeper-dir> --op admit|expel \
//       --member <did> --deciders <did,did,...> [--rationale R] --out <file>
//   dart run tool/staff_govern.dart assemble     <keeper-dir> --pending <file> \
//       --sigs <file>
//   dart run tool/staff_govern.dart induct       <keeper-dir> --member <dir> \
//       --attending <dir,dir,...>
//   dart run tool/staff_govern.dart depart       <keeper-dir> --member <dir>
//   dart run tool/staff_govern.dart publish-roll <keeper-dir> --out <file>
//   dart run tool/staff_govern.dart verify-roll  --roll <file>
//
// Needs the cdylib: AGORA_ETHNE_PATH, or native/build/libethne_agora.{so,dylib}.

import 'dart:convert';
import 'dart:io';

import 'package:agora/src/ffi/ethne_bindings.dart';
import 'package:agora/src/model/staff_identity.dart';

String _arg(List<String> a, String flag, String dflt) {
  final i = a.indexOf(flag);
  return (i >= 0 && i + 1 < a.length) ? a[i + 1] : dflt;
}

List<String> _list(List<String> a, String flag) {
  final v = _arg(a, flag, '');
  return v.isEmpty ? <String>[] : v.split(',');
}

File _identityFile(String dir) => File('$dir/etc/at/agora.polity.json');

Never _die(String msg, [int code = 3]) {
  stderr.writeln(msg);
  exit(code);
}

Future<StaffIdentity> _load(String dir) async {
  final store = await StaffIdentityStore(_identityFile(dir)).load();
  final id = store.identity;
  if (id == null) _die('no usable staff identity at ${_identityFile(dir).path}');
  return id;
}

/// Persist the keeper's log after an act, through the same store the app uses.
Future<void> _save(String dir, StaffIdentity id, EthneArchive arc) async {
  final store = StaffIdentityStore(_identityFile(dir))..identity = id;
  store.updateArchive(jsonDecode(arc.dumpJson()) as Map<String, dynamic>);
  await store.save();
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) _die('usage: staff_govern.dart <subcommand> ...', 2);
  final cmd = args.first;

  final libPath = EthneFfi.resolveLibraryPath();
  if (libPath == null) {
    _die(
        'ethne_agora not found (set AGORA_ETHNE_PATH or build '
        'native/build/libethne_agora.{so,dylib})',
        2);
  }
  final ffi = EthneFfi.open(libPath);

  // verify-roll needs no log at all — it is exactly what a stranger can do.
  if (cmd == 'verify-roll') {
    final path = _arg(args, '--roll', '');
    if (path.isEmpty) _die('verify-roll needs --roll <file>', 2);
    final roll = File(path).readAsStringSync();
    final ok = ffi.verifyMemberRoll(roll);
    stdout.writeln(jsonEncode({
      'publisher_proven': ok,
      if (!ok) 'error': ffi.lastError(),
    }));
    exit(ok ? 0 : 1);
  }

  if (args.length < 2) _die('$cmd needs a keeper directory', 2);
  final keeperDir = args[1];
  final keeper = await _load(keeperDir);
  final arc = ffi.loadArchive(jsonEncode(keeper.archive));
  try {
    switch (cmd) {
      case 'state':
        final st = arc.affirmationState(keeper.polityDid);
        stdout.writeln(jsonEncode({
          'verified': arc.verify(),
          'roll': st['roll'],
          'seasoned': st['seasoned'],
          'admit_need': st['admit_need'],
          'expel_need': st['expel_need'],
          'can_contract': st['can_contract'],
          'members': st['members'],
          'envoys': arc.envoyState(keeper.polityDid),
        }));
        break;

      case 'pend':
        final op = _arg(args, '--op', '');
        final member = _arg(args, '--member', '');
        final deciders = _list(args, '--deciders');
        final out = _arg(args, '--out', '');
        if (op.isEmpty || member.isEmpty || out.isEmpty) {
          _die('pend needs --op, --member and --out', 2);
        }
        final ex = arc.pendingChange(
          op: op,
          polityDid: keeper.polityDid,
          memberDid: member,
          rationale: _arg(args, '--rationale', 'cohort run'),
          deciderDids: deciders,
        );
        File(out).writeAsStringSync(jsonEncode(ex));
        // The description is printed for the operator's eyes only. It does NOT
        // go into the exchange the cohort puts on the wire — the signer's own
        // node derives its own from the bytes.
        stdout.writeln(jsonEncode({
          'record': ex['record'],
          'op': ex['op'],
          'cid': ex['cid'],
          'bytes_len': (ex['bytes'] as String).length,
          'signers_required': ex['signers_required'],
          'description': ex['description'],
        }));
        break;

      case 'assemble':
        final pend = jsonDecode(
            File(_arg(args, '--pending', '')).readAsStringSync()) as Map;
        final rawSigs = jsonDecode(
            File(_arg(args, '--sigs', '')).readAsStringSync()) as List;
        final sigs = <({String did, String sig})>[
          for (final s in rawSigs)
            (did: (s as Map)['did'] as String, sig: s['sig'] as String),
        ];
        arc.assembleSigned(
          payload: (pend['payload'] as Map).cast<String, dynamic>(),
          signatures: sigs,
          record: pend['record'] as String? ?? 'membership',
        );
        await _save(keeperDir, keeper, arc);
        final after = arc.affirmationState(keeper.polityDid);
        stdout.writeln(jsonEncode({
          'assembled': true,
          'signatures': sigs.length,
          'verified': arc.verify(),
          'roll': after['roll'],
          'seasoned': after['seasoned'],
        }));
        break;

      case 'induct':
        final memberId = await _load(_arg(args, '--member', ''));
        final attending = <EthneKeypair>[
          for (final d in _list(args, '--attending')) (await _load(d)).self,
        ];
        final member = memberId.self;
        // THE SUBSTRATE MOVEMENT MUST NAME THIS CHARTER'S SUBSTRATE, not a
        // pretty phrase. The authority pass checks the name the newcomer recites
        // against the charter's own, and a mismatch leaves a log that folds up
        // looking inducted and refuses to verify:
        //
        //   authority error: movement 1 names substrate "..." but the
        //   charter's is "Corner Cafe"
        //
        // Read it out of the charter rather than hardcoding it, so this keeps
        // working when the fixture is minted with --name.
        final substrate =
            (arc.charterState(keeper.polityDid)['substrate']
                as Map)['name'] as String;
        // The five movements, in the one order the core accepts.
        final cids = <String>[
          arc.reciteMovement(
              polityDid: keeper.polityDid,
              member: member,
              movement: {'Substrate': {'names': substrate}},
              statement: 'I name the ground we stand on.',
              attending: attending),
          arc.reciteMovement(
              polityDid: keeper.polityDid,
              member: member,
              movement: 'Fallenness',
              statement: 'I will fall short of it.',
              attending: attending),
          arc.reciteMovement(
              polityDid: keeper.polityDid,
              member: member,
              movement: 'Recognition',
              statement: 'I see the rest of the roll.',
              attending: attending),
          arc.reciteMovement(
              polityDid: keeper.polityDid,
              member: member,
              movement: {'CommonVirtue': {'commits_to': <String>[]}},
              statement: 'I commit to what this polity binds itself to.',
              attending: attending),
          arc.reciteMovement(
              polityDid: keeper.polityDid,
              member: member,
              movement: {'NonUltimacy': {'names_anchor': null}},
              statement: 'This polity is not the last word.',
              attending: attending),
        ];
        arc.inductMember(
          polityDid: keeper.polityDid,
          member: member,
          movementCids: cids,
          witnesses: attending,
        );
        await _save(keeperDir, keeper, arc);
        final ist = arc.affirmationState(keeper.polityDid);
        stdout.writeln(jsonEncode({
          'inducted': member.did,
          'verified': arc.verify(),
          'seasoned': ist['seasoned'],
          'expel_need': ist['expel_need'],
        }));
        break;

      case 'depart':
        final leaver = (await _load(_arg(args, '--member', ''))).self;
        arc.departMember(
          polityDid: keeper.polityDid,
          member: leaver,
          rationale: 'moving on',
        );
        await _save(keeperDir, keeper, arc);
        final dst = arc.affirmationState(keeper.polityDid);
        stdout.writeln(jsonEncode({
          'departed': leaver.did,
          'verified': arc.verify(),
          'roll': dst['roll'],
          'seasoned': dst['seasoned'],
          // An office is conferred by the roll and lapses with it.
          'envoys': arc.envoyState(keeper.polityDid),
        }));
        break;

      case 'publish-roll':
        final root = keeper.root;
        if (root == null) {
          _die('this node holds no polity root key, so it cannot publish a roll');
        }
        final roll =
            arc.signMemberRoll(polityDid: keeper.polityDid, root: root);
        final out = _arg(args, '--out', '');
        if (out.isNotEmpty) File(out).writeAsStringSync(roll);
        stdout.writeln(jsonEncode({
          // Two answers, kept apart: what a stranger could establish, and what
          // only a holder of this log can.
          'publisher_proven': ffi.verifyMemberRoll(roll),
          'audited_against_log': arc.verifyMemberRollFull(roll),
        }));
        break;

      default:
        _die('unknown subcommand: $cmd', 2);
    }
  } on EthneException catch (e) {
    _die('$cmd refused: $e', 1);
  } finally {
    arc.dispose();
  }
}

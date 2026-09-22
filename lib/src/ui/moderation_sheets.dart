// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The two moderation dialogs (Phase 4 P4.1): confirming a block, and the report
// sheet. Both say plainly what will and will not happen, because the two
// actions are easy to confuse and do very different things:
//
//   - a BLOCK is local. Nothing crosses the wire and the person is not told.
//   - a REPORT is your first-person account that an exchange went badly. It
//     lowers their standing a little, once a day at most, and the reason you
//     pick never leaves this device.
//
// A report does not block. "Report and block" is offered as the one button that
// does both, and it sends two separate verbs.

import 'package:flutter/material.dart';

import '../ffi/at_peer.dart';
import '../model/moderation.dart';
import '../node/peer_stream.dart';

/// Ask before blocking [peer]. Returns true when the operator confirmed.
Future<bool> confirmBlock(BuildContext context, AgoraPeer peer) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Block ${peer.displayLabel}?'),
      content: const Text(
        'You will stop seeing their posts, messages and reactions on this '
        'device. They stay in your list so you can unblock them later.\n\n'
        'Nothing is sent to them, and they are not told.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-block'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Block'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// What the report sheet decided.
enum ReportChoice { report, reportAndBlock }

/// The operator's answer from [showReportSheet].
class ReportDecision {
  const ReportDecision(this.choice, this.reason);
  final ReportChoice choice;
  final ReportReason reason;
}

/// Show the report sheet for [peer]. Null when cancelled.
Future<ReportDecision?> showReportSheet(BuildContext context, AgoraPeer peer) {
  return showModalBottomSheet<ReportDecision>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _ReportSheet(peer: peer),
  );
}

/// Show the sheet, send what the operator chose, and say what happened.
Future<void> reportFlow(
    BuildContext context, PeerService service, AgoraPeer peer) async {
  final decision = await showReportSheet(context, peer);
  if (decision == null || !context.mounted) return;
  final rc = decision.choice == ReportChoice.reportAndBlock
      ? service.blockAndReport(peer, decision.reason)
      : service.reportPeer(peer, decision.reason);
  final msg = switch (rc) {
    0 => decision.choice == ReportChoice.reportAndBlock
        ? 'Reported and blocked'
        : 'Reported',
    reportRefusedCap => 'You already reported them today',
    -2 => 'Not connected yet',
    _ => 'Could not report',
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.peer});
  final AgoraPeer peer;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  ReportReason? _reason;

  void _done(ReportChoice choice) =>
      Navigator.of(context).pop(ReportDecision(choice, _reason!));

  @override
  Widget build(BuildContext context) {
    final name = widget.peer.displayLabel;
    final ready = _reason != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Report $name', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'A report is your own account that an exchange with $name went '
              'badly. It lowers their standing a little. You can report '
              'someone once a day.\n\n'
              'The reason you pick stays on this device. $name\'s app does not '
              'tell them they were reported, and reporting does not block '
              'them.',
              key: const Key('report-statement'),
            ),
            const SizedBox(height: 8),
            RadioGroup<ReportReason>(
              groupValue: _reason,
              onChanged: (v) => setState(() => _reason = v),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final r in ReportReason.values)
                    RadioListTile<ReportReason>(
                      key: Key('reason-${r.code}'),
                      dense: true,
                      value: r,
                      title: Text(r.label),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                OutlinedButton(
                  key: const Key('report-and-block'),
                  onPressed:
                      ready ? () => _done(ReportChoice.reportAndBlock) : null,
                  child: const Text('Report and block'),
                ),
                FilledButton(
                  key: const Key('report-send'),
                  onPressed: ready ? () => _done(ReportChoice.report) : null,
                  child: const Text('Report'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Starting an expulsion (Phase 4 P4.1) — the first act this app initiates
// rather than answers. Three choices, all made by hand:
//
//   - WHO DECIDES: seasoned members other than the one being expelled. The bar
//     is majority plus one, higher than admission's on purpose.
//   - WHOM TO ASK: which peers on the segment to send the ask to. There is no
//     DID→peer mapping, so this is a manual pick — and a wrong pick fails
//     safely, because every signature is checked against the act on assembly.
//   - WHICH PEER THIS MEMBER IS, optionally, so the reputation consequence can
//     follow once the act has landed. Leave it unset and the act still lands;
//     no standing is handed to the core.
//
// Nothing here applies anything. It opens the exchange and sends the asks; the
// act lands only when every decider has signed and the log re-verifies.

import 'package:flutter/material.dart' hide ConnectionState;

import '../ffi/at_peer.dart';
import '../model/staff_roster.dart';
import '../node/peer_stream.dart';

/// Show the dialog. Returns whether an exchange was opened.
Future<bool> showExpelDialog(BuildContext context,
    {required PeerService service,
    required StaffRoster roster,
    required StaffMember member}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) =>
        _ExpelDialog(service: service, roster: roster, member: member),
  );
  return ok ?? false;
}

class _ExpelDialog extends StatefulWidget {
  const _ExpelDialog(
      {required this.service, required this.roster, required this.member});
  final PeerService service;
  final StaffRoster roster;
  final StaffMember member;

  @override
  State<_ExpelDialog> createState() => _ExpelDialogState();
}

class _ExpelDialogState extends State<_ExpelDialog> {
  final _rationale = TextEditingController();
  final Set<String> _deciders = {};
  final Set<String> _ask = {};
  String? _targetHex;
  String? _error;

  static String _hex(List<int> u) =>
      u.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  List<StaffMember> get _eligible => widget.roster.members
      .where((m) => m.inducted && m.did != widget.member.did)
      .toList();

  List<AgoraPeer> get _peers =>
      widget.service.peers.where((p) => !p.blocked).toList();

  @override
  void initState() {
    super.initState();
    // This node decides if it can: its own key is here.
    final own = widget.service.staffIdentity?.did;
    if (own != null && _eligible.any((m) => m.did == own)) _deciders.add(own);
  }

  @override
  void dispose() {
    _rationale.dispose();
    super.dispose();
  }

  bool get _ready =>
      _rationale.text.trim().isNotEmpty &&
      _deciders.length >= widget.roster.expelNeed;

  void _submit() {
    final peers = _peers;
    final target = _targetHex == null
        ? null
        : peers.where((p) => _hex(p.uuid) == _targetHex).firstOrNull;
    final ax = widget.service.beginExpulsion(
      memberDid: widget.member.did,
      rationale: _rationale.text.trim(),
      deciderDids: _deciders.toList(),
      askPeers: peers.where((p) => _ask.contains(_hex(p.uuid))).toList(),
      targetPeer: target,
    );
    if (ax == null) {
      setState(() => _error = widget.service.lastExpulsionError);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final own = widget.service.staffIdentity?.did;
    return AlertDialog(
      title: const Text('Expel a member'),
      content: SizedBox(
        width: 480,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(widget.member.did,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 8),
            Text(
              'An expulsion is done TO somebody. It needs '
              '${widget.roster.expelNeed} deciders — majority plus one of the '
              'seasoned roll — and the member being expelled does not sign. '
              'Once it lands, their standing on this node is capped: a '
              'reputation event, not a cut-off.',
              style: small,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('expel-rationale'),
              controller: _rationale,
              decoration: const InputDecoration(labelText: 'Reason (recorded)'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Text('Who decides (${_deciders.length} of '
                '${widget.roster.expelNeed} needed)'),
            for (final m in _eligible)
              CheckboxListTile(
                key: Key('decider-${m.did}'),
                dense: true,
                value: _deciders.contains(m.did),
                title: Text(m.did == own ? '${m.did} (you)' : m.did,
                    style: const TextStyle(fontSize: 12)),
                onChanged: (v) => setState(() =>
                    v == true ? _deciders.add(m.did) : _deciders.remove(m.did)),
              ),
            const SizedBox(height: 12),
            const Text('Whom to ask for a signature'),
            Text(
              'There is no link from a member to a peer, so pick by hand. A '
              'wrong pick only means a signature does not come back.',
              style: small,
            ),
            if (_peers.isEmpty)
              Text('No peers on the segment.', style: small)
            else
              for (final p in _peers)
                CheckboxListTile(
                  key: Key('ask-${p.shortId}'),
                  dense: true,
                  value: _ask.contains(_hex(p.uuid)),
                  title: Text(p.displayLabel),
                  onChanged: (v) => setState(() => v == true
                      ? _ask.add(_hex(p.uuid))
                      : _ask.remove(_hex(p.uuid))),
                ),
            const SizedBox(height: 12),
            const Text('Which peer is this member? (optional)'),
            DropdownButton<String?>(
              key: const Key('expel-target'),
              isExpanded: true,
              value: _targetHex,
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('Not on this segment / not sure')),
                for (final p in _peers)
                  DropdownMenuItem<String?>(
                      value: _hex(p.uuid), child: Text(p.displayLabel)),
              ],
              onChanged: (v) => setState(() => _targetHex = v),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  key: const Key('expel-error'),
                  style: TextStyle(color: scheme.error, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('expel-submit'),
          onPressed: _ready ? _submit : null,
          child: const Text('Ask deciders to sign'),
        ),
      ],
    );
  }
}

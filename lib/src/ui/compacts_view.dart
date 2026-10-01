// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// A community's kith-covenant compacts, as its staff work them (SOCIAL_APP_PLAN
// Phase 5; Ethne D39, D40). Two kinds of thing happen here, deliberately apart:
//
//  - the ROLL decides: join or found a compact, admit or sponsor an entrant,
//    refuse one, report one for anathema, lift a designation. Each is a co-signed
//    act in the charter log, a majority (more than a majority to bear down on
//    another community);
//  - the governance node then CARRIES OUT what was decided at KC's border:
//    cross it (identity, envoy, the rite), present the five claims, answer
//    another community's, vouch, seat examiners, convene a seal, file a report.
//    Each refuses what no act in force covers.

import 'package:flutter/material.dart';

import '../model/compact_book.dart';
import '../node/peer_stream.dart';
import 'communities_view.dart';

class CompactsPage extends StatelessWidget {
  const CompactsPage({super.key, required this.service});
  final PeerService service;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Compacts')),
        body: ListenableBuilder(
          listenable: service,
          builder: (context, _) {
            final own = service.ownPolityDid;
            final view = own == null ? null : service.compactBook.views[own];
            final engine = service.compactEngine;
            final small = TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant);
            return ListView(padding: const EdgeInsets.all(12), children: [
              Text(
                  'A compact is a covenant between communities, each admitted by its own '
                  'rite and the others\' recognition. What your community does in one is '
                  'the roll\'s decision; this node then carries it out.',
                  style: small),
              const SizedBox(height: 12),
              if (view == null || view.compacts.isEmpty)
                const Text('Your community sits in no compact yet.', key: Key('no-compacts'))
              else
                for (final c in view.compacts)
                  Card(
                    key: Key('compact-${c.label}'),
                    child: ListTile(
                      title: Text(c.label),
                      subtitle: Text('${c.members.length} other member(s)\n'
                          '${c.members.map((m) => '$m · ${standingBadge(view.standings[m] ?? CompactStanding.outside) ?? ''}').join('\n')}'),
                    ),
                  ),
              if (view != null && view.standings.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('How other communities stand with yours'),
                for (final e in view.standings.entries)
                  Text('${e.key}: ${e.value.name}', style: small),
              ],
              const Divider(),
              FilledButton.tonal(
                key: const Key('compact-decide'),
                onPressed: service.staffRoster == null
                    ? null
                    : () => showDialog<void>(context: context, builder: (_) => _ActDialog(service: service)),
                child: const Text('Ask the roll to decide a compact act…'),
              ),
              const SizedBox(height: 12),
              if (engine == null)
                Text('This node holds no compact replica (it is staff of no community, or the '
                    'Ethne library is absent).', style: small)
              else ...[
                Text('At the border', style: Theme.of(context).textTheme.titleSmall),
                Text('${engine.unacknowledged} record(s) waiting for a member\'s receipt.', style: small),
                if (engine.lastError != null)
                  Text(engine.lastError!, key: const Key('compact-error'),
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (engine.border.governs) ...[
                    OutlinedButton(
                      key: const Key('compact-cross'),
                      onPressed: () => _cross(context, service),
                      child: const Text('Cross the border'),
                    ),
                    OutlinedButton(
                      key: const Key('compact-present'),
                      onPressed: () => _compactAnd(context, service, 'Present our claims to',
                          (compact, did) => engine.present(compact, [did])),
                      child: const Text('Present our claims…'),
                    ),
                    OutlinedButton(
                      key: const Key('compact-accept'),
                      onPressed: () => _compactAnd(context, service, 'Accept the claims of',
                          (compact, did) => engine.answerClaims(compact, did)),
                      child: const Text('Accept their claims…'),
                    ),
                    OutlinedButton(
                      key: const Key('compact-refuse'),
                      onPressed: () => _compactAnd(context, service, 'Refuse the claims of',
                          (compact, did) => engine.answerClaims(compact, did, accepted: false)),
                      child: const Text('Refuse their claims…'),
                    ),
                    OutlinedButton(
                      key: const Key('compact-vouch'),
                      onPressed: () => _compactAnd(context, service, 'Vouch for',
                          (compact, did) => engine.vouch(compact, did)),
                      child: const Text('Vouch for an entrant…'),
                    ),
                    OutlinedButton(
                      key: const Key('compact-seat'),
                      onPressed: () => _seat(context, service),
                      child: const Text('Seat examiners…'),
                    ),
                    OutlinedButton(
                      key: const Key('compact-convene'),
                      onPressed: () => _convene(context, service),
                      child: const Text('Convene the seal…'),
                    ),
                    OutlinedButton(
                      key: const Key('compact-report'),
                      onPressed: () => _compactAnd(context, service, 'Report for anathema', (compact, did) {
                        final co = {
                          for (final m in service.compactMates)
                            if (m != did && service.compactBook.nodeOf(m) != null) m: service.compactBook.nodeOf(m)!
                        };
                        return engine.report('anathema', compact, co, did);
                      }),
                      child: const Text('Report for anathema…'),
                    ),
                  ],
                ]),
              ],
            ]);
          },
        ),
      );

  static void _report(BuildContext context, bool ok, String? error) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? 'Done. Members receive it as they are reached.' : 'Refused: $error')));
  }

  /// Every community this node has heard of: policies, views, compact-mates.
  static List<String> knownCommunities(PeerService s) => {
        ...s.communities.followed.keys,
        ...s.communities.heard.keys,
        ...s.compactBook.views.keys,
      }.where((d) => d != s.ownPolityDid).toList()
        ..sort();

  static Future<void> _compactAnd(BuildContext context, PeerService service, String what,
      bool Function(String compact, String did) act) async {
    final picked = await showDialog<(String, String)>(
        context: context, builder: (_) => _CompactAndCommunity(service: service, title: what));
    if (picked == null || !context.mounted) return;
    final engine = service.compactEngine!;
    _report(context, act(picked.$1, picked.$2), engine.lastError);
  }

  static Future<void> _pickPeers(
      BuildContext context, PeerService service, String title, void Function(List<String>) then) async {
    final ask = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 420,
            child: ListView(shrinkWrap: true, children: [
              for (final p in service.peers.where((p) => !p.blocked))
                CheckboxListTile(
                  dense: true,
                  value: ask.contains(_hex(p.uuid)),
                  title: Text(p.displayLabel),
                  onChanged: (v) => set(() => v == true ? ask.add(_hex(p.uuid)) : ask.remove(_hex(p.uuid))),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Go')),
          ],
        ),
      ),
    );
    if (ok == true) then(ask.toList());
  }

  static String _hex(List<int> u) => u.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// The rite crosses with the Inductor reciting it: a member other than you,
  /// the envoy (KC holds one delegation per speaker), on their own device.
  static Future<void> _cross(BuildContext context, PeerService service) async {
    final roster = service.staffRoster;
    final engine = service.compactEngine!;
    final own = service.staffIdentity?.did;
    if (roster == null) return;
    final candidates = [for (final m in roster.members.where((m) => m.inducted)) if (m.did != own) m.did];
    String? inductor = candidates.isEmpty ? null : candidates.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Who recites the rite?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('The Inductor recites; the members who attended the rite witness. '
                'Pick the Inductor, then which nodes to ask.'),
            DropdownButton<String>(
              key: const Key('cross-inductor'),
              isExpanded: true,
              value: inductor,
              items: [
                for (final d in candidates) DropdownMenuItem(value: d, child: Text(d, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => set(() => inductor = v),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: inductor == null ? null : () => Navigator.of(context).pop(true),
                child: const Text('Next')),
          ],
        ),
      ),
    );
    if (ok != true || inductor == null || !context.mounted) return;
    await _pickPeers(context, service, 'Ask which nodes (the Inductor\'s, the witnesses\')?',
        (nodes) => _report(context, engine.crossBorder(inductorDid: inductor!, witnessNodes: nodes), engine.lastError));
  }

  static Future<void> _seat(BuildContext context, PeerService service) async {
    final roster = service.staffRoster;
    final engine = service.compactEngine!;
    if (roster == null) return;
    final seats = <String>{if (service.staffIdentity != null) service.staffIdentity!.did};
    final nodes = <String, String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Seat examiners (182 days at most)'),
          content: SizedBox(
            width: 460,
            child: ListView(shrinkWrap: true, children: [
              const Text('KC needs three seated examiners, from two or more sitting communities, '
                  'to admit an entrant. A seat on another device also receives the compact\'s records.'),
              for (final m in roster.members.where((m) => m.inducted))
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CheckboxListTile(
                    dense: true,
                    value: seats.contains(m.did),
                    title: Text(m.did, style: const TextStyle(fontSize: 12)),
                    onChanged: (v) => set(() => v == true ? seats.add(m.did) : seats.remove(m.did)),
                  ),
                  if (seats.contains(m.did) && m.did != service.staffIdentity?.did)
                    DropdownButton<String>(
                      hint: const Text('Their node'),
                      value: nodes[m.did],
                      items: [
                        for (final p in service.peers)
                          DropdownMenuItem(value: _hex(p.uuid), child: Text(p.displayLabel)),
                      ],
                      onChanged: (v) => set(() => v == null ? nodes.remove(m.did) : nodes[m.did] = v),
                    ),
                ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Seat them')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    _report(
        context,
        engine.seat([
          for (final d in seats) {'did': d, if (nodes[d] != null) 'node': nodes[d]}
        ]),
        engine.lastError);
  }

  static Future<void> _convene(BuildContext context, PeerService service) async {
    final engine = service.compactEngine!;
    final label = TextEditingController(text: 'compact');
    final chosen = <String>[];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Convene the seal'),
          content: SizedBox(
            width: 460,
            child: ListView(shrinkWrap: true, children: [
              TextField(controller: label, decoration: const InputDecoration(labelText: 'Compact')),
              const Text('Participants, in order: sitting members first, the entrant last. Yours is '
                  'first. At most three: the carrier holds no more.'),
              for (final d in knownCommunities(service))
                CheckboxListTile(
                  dense: true,
                  value: chosen.contains(d),
                  title: Text(d, style: const TextStyle(fontSize: 12)),
                  onChanged: (v) => set(() => v == true ? chosen.add(d) : chosen.remove(d)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(
                onPressed: chosen.isEmpty || chosen.length > 2 ? null : () => Navigator.of(context).pop(true),
                child: const Text('Ask them to sign')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final participants = [service.ownPolityDid!, ...chosen];
    final nodes = [
      for (final d in chosen)
        if (service.compactBook.nodeOf(d) != null) service.compactBook.nodeOf(d)!,
      ...engine.examinerNodes,
    ];
    _report(context, engine.convene(label.text.trim(), participants, nodes), engine.lastError);
  }
}

class _CompactAndCommunity extends StatefulWidget {
  const _CompactAndCommunity({required this.service, required this.title});
  final PeerService service;
  final String title;

  @override
  State<_CompactAndCommunity> createState() => _CompactAndCommunityState();
}

class _CompactAndCommunityState extends State<_CompactAndCommunity> {
  final _label = TextEditingController(text: 'compact');
  String? _did;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final known = CompactsPage.knownCommunities(widget.service);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(key: const Key('compact-label'), controller: _label,
            decoration: const InputDecoration(labelText: 'Compact')),
        DropdownButton<String>(
          key: const Key('compact-community'),
          isExpanded: true,
          hint: const Text('Community'),
          value: _did,
          items: [
            for (final d in known)
              DropdownMenuItem(value: d, child: Text(d, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _did = v),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
            onPressed: _did == null ? null : () => Navigator.of(context).pop((_label.text.trim(), _did!)),
            child: const Text('Go')),
      ],
    );
  }
}

/// The roll deciding a compact act (D40).
class _ActDialog extends StatefulWidget {
  const _ActDialog({required this.service});
  final PeerService service;

  @override
  State<_ActDialog> createState() => _ActDialogState();
}

class _ActDialogState extends State<_ActDialog> {
  static const kinds = ['Join', 'Admit', 'Sponsor', 'Refuse', 'Anathematize', 'Lift'];
  String _kind = 'Join';
  final _label = TextEditingController(text: 'compact');
  final _days = TextEditingController(text: '90');
  final _why = TextEditingController();
  final Set<String> _others = {};
  final Set<String> _deciders = {};
  final Set<String> _ask = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    final own = widget.service.staffIdentity?.did;
    if (own != null) _deciders.add(own);
  }

  @override
  void dispose() {
    _label.dispose();
    _days.dispose();
    _why.dispose();
    super.dispose();
  }

  bool get _severe => _kind == 'Refuse' || _kind == 'Anathematize';

  void _submit() {
    final ax = widget.service.beginCompactAct(
      kind: _kind,
      compact: _label.text.trim(),
      counterparties: _others.toList()..sort(),
      probationDays: _kind == 'Sponsor' ? int.tryParse(_days.text.trim()) : null,
      rationale: _why.text.trim(),
      deciderDids: _deciders.toList(),
      askPeers: askPeersOf(widget.service, _ask),
    );
    if (ax == null) {
      setState(() => _error = widget.service.lastCommunityError);
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final roster = widget.service.staffRoster!;
    final need = roster.admitNeed + (_severe ? 1 : 0);
    return AlertDialog(
      title: const Text('A compact act'),
      content: SizedBox(
        width: 480,
        child: ListView(shrinkWrap: true, children: [
          DropdownButton<String>(
            key: const Key('act-kind'),
            value: _kind,
            items: [for (final k in kinds) DropdownMenuItem(value: k, child: Text(k))],
            onChanged: (v) => setState(() => _kind = v ?? 'Join'),
          ),
          Text(_severe
              ? 'This bears down on another community, so it needs more than a majority.'
              : 'A majority decides this.'),
          TextField(key: const Key('act-compact'), controller: _label,
              decoration: const InputDecoration(labelText: 'Compact ([a-z0-9_-])')),
          if (_kind == 'Sponsor')
            TextField(key: const Key('act-days'), controller: _days, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Probation (days)')),
          const SizedBox(height: 8),
          const Text('Towards'),
          for (final d in CompactsPage.knownCommunities(widget.service))
            CheckboxListTile(
              dense: true,
              value: _others.contains(d),
              title: Text(d, style: const TextStyle(fontSize: 12)),
              onChanged: (v) => setState(() => v == true ? _others.add(d) : _others.remove(d)),
            ),
          TextField(controller: _why, decoration: const InputDecoration(labelText: 'Why (recorded)')),
          Signers(
            service: widget.service,
            roster: roster,
            need: '$need',
            deciders: _deciders,
            ask: _ask,
            onChanged: () => setState(() {}),
          ),
          if (_error != null)
            Text(_error!, key: const Key('act-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('act-submit'),
          onPressed: _others.isEmpty || _deciders.length < need ? null : _submit,
          child: const Text('Ask deciders to sign'),
        ),
      ],
    );
  }
}

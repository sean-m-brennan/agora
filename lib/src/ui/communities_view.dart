// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Communities (Phase 4, Ethne D37): the content policies this reader has heard,
// follows, and applies.
//
// A community is a polity. Its roll sets how content posted in its name is
// moderated, and its root key signs that policy. Following a community is what
// makes its policy apply to this reader's feed AND what makes this node carry
// the policy and the community's labels to others. The policy binds no one:
// "apply to my feed" is this reader's switch, and turning it off hides nothing
// and changes nothing anywhere else.
//
// For a member, the same page proposes a new policy and seats or unseats a
// Moderator. Both are roll acts: they open a co-signing exchange, like an
// expulsion, and land only when enough deciders have signed and the log still
// verifies — a loosening short of more than a majority is refused on assembly.

import 'package:flutter/material.dart';

import '../ffi/at_peer.dart';
import '../model/community_policy.dart';
import '../model/compact_book.dart';
import '../model/staff_roster.dart';
import '../node/peer_stream.dart';
import 'compacts_view.dart';

class CommunitiesPage extends StatelessWidget {
  const CommunitiesPage({super.key, required this.service});

  final PeerService service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Communities')),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final book = service.communities;
          final dids = {...book.followed.keys, ...book.heard.keys}.toList()
            ..sort();
          if (dids.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No community policy heard yet. Members of a community carry '
                  'its policy; when one reaches you it appears here.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final mates = service.compactMates
              .where((d) => !book.followed.containsKey(d) && !book.heard.containsKey(d))
              .toList()
            ..sort();
          return ListView(
            padding: const EdgeInsets.all(8),
            children: [
              if (mates.isNotEmpty)
                Card(
                  key: const Key('compact-mates'),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('In compact with your communities'),
                      const Text(
                          'Their policies reach you once one of their members carries it near you.',
                          style: TextStyle(fontSize: 12)),
                      for (final d in mates)
                        Text(d, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                    ]),
                  ),
                ),
              for (final did in dids)
                _CommunityCard(
                  service: service,
                  did: did,
                  followed: book.followed[did],
                  heard: book.heard[did],
                  applied: !book.disabled.contains(did),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CommunityCard extends StatelessWidget {
  const _CommunityCard({
    required this.service,
    required this.did,
    required this.followed,
    required this.heard,
    required this.applied,
  });

  final PeerService service;
  final String did;
  final CommunityPolicy? followed;
  final CommunityPolicy? heard;
  final bool applied;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final shown = followed ?? heard!;
    final member = did == service.ownPolityDid;
    return Card(
      key: Key('community-$did'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(did,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            Text(
                'Policy version ${shown.seq}'
                '${member ? ' · you are a member' : ''}'
                '${service.canModerate(did) ? ' · you moderate' : ''}',
                style: small),
            if (standingBadge(service.standingOfCommunity(did) ?? CompactStanding.outside)
                case final badge?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Chip(
                  key: Key('standing-$did'),
                  label: Text(badge, style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            const SizedBox(height: 8),
            ..._rules(shown, small),
            const SizedBox(height: 8),
            if (followed == null)
              FilledButton(
                key: Key('follow-$did'),
                onPressed: () => service.followCommunity(did),
                child: const Text('Follow this community'),
              )
            else ...[
              SwitchListTile(
                key: Key('apply-$did'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Apply this policy to my feed'),
                subtitle: Text(
                    'Only your own view. You still carry the policy for others.',
                    style: small),
                value: applied,
                onChanged: (v) => service.setCommunityPolicyApplied(did, v),
              ),
              TextButton(
                key: Key('unfollow-$did'),
                onPressed: () => service.unfollowCommunity(did),
                child: const Text('Unfollow'),
              ),
            ],
            if (member && service.canGovernCommunity)
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    key: const Key('propose-policy'),
                    onPressed: () =>
                        _proposePolicy(context, service, followed ?? heard),
                    child: const Text('Propose a policy…'),
                  ),
                  OutlinedButton(
                    key: const Key('seat-moderator'),
                    onPressed: () => _moderatorChange(context, service,
                        (followed ?? heard)?.moderators ?? const []),
                    child: const Text('Moderators…'),
                  ),
                  OutlinedButton(
                    key: const Key('open-compacts'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => CompactsPage(service: service))),
                    child: const Text('Compacts…'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static List<Widget> _rules(CommunityPolicy p, TextStyle small) => [
        Text(p.operatorBoundRequired
            ? 'Authors must have an operator answering for them.'
            : 'Any author may post.'),
        if (p.minTier > 0)
          Text('Authors below trust tier ${p.minTier} are hidden.'),
        if (p.dailyPostCap != null)
          Text('At most ${p.dailyPostCap} posts per author a day.'),
        for (final e in p.labels.entries)
          Text('"${e.key}": ${switch (e.value) {
            LabelAction.hide => 'hidden',
            LabelAction.warn => 'behind a warning',
            LabelAction.allow => 'shown as a tag',
          }}'),
        Text(
            p.moderators.isEmpty
                ? 'No moderators.'
                : '${p.moderators.length} moderator(s).',
            style: small),
      ];
}

/// The deciders and whom to ask, the two picks every roll act needs.
class Signers extends StatefulWidget {
  const Signers({
    super.key,
    required this.service,
    required this.roster,
    required this.need,
    required this.deciders,
    required this.ask,
    required this.onChanged,
  });

  final PeerService service;
  final StaffRoster roster;
  final String need;
  final Set<String> deciders;
  final Set<String> ask;
  final VoidCallback onChanged;

  @override
  State<Signers> createState() => _SignersPickState();
}

class _SignersPickState extends State<Signers> {
  static String _hex(List<int> u) =>
      u.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  @override
  Widget build(BuildContext context) {
    final own = widget.service.staffIdentity?.did;
    final peers = widget.service.peers.where((p) => !p.blocked).toList();
    void toggle(Set<String> s, String k, bool? v) {
      setState(() => v == true ? s.add(k) : s.remove(k));
      widget.onChanged();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Who decides (${widget.deciders.length}; ${widget.need})'),
        for (final m in widget.roster.members.where((m) => m.inducted))
          CheckboxListTile(
            key: Key('decider-${m.did}'),
            dense: true,
            value: widget.deciders.contains(m.did),
            title: Text(m.did == own ? '${m.did} (you)' : m.did,
                style: const TextStyle(fontSize: 12)),
            onChanged: (v) => toggle(widget.deciders, m.did, v),
          ),
        const SizedBox(height: 8),
        const Text('Whom to ask for a signature'),
        for (final AgoraPeer p in peers)
          CheckboxListTile(
            key: Key('ask-${p.shortId}'),
            dense: true,
            value: widget.ask.contains(_hex(p.uuid)),
            title: Text(p.displayLabel),
            onChanged: (v) => toggle(widget.ask, _hex(p.uuid), v),
          ),
      ],
    );
  }
}

List<AgoraPeer> askPeersOf(PeerService service, Set<String> ask) {
  String hex(List<int> u) =>
      u.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return service.peers.where((p) => ask.contains(hex(p.uuid))).toList();
}

Future<void> _proposePolicy(
    BuildContext context, PeerService service, CommunityPolicy? current) async {
  final roster = service.staffRoster;
  if (roster == null) return;
  final opened = await showDialog<bool>(
    context: context,
    builder: (_) =>
        _PolicyDialog(service: service, roster: roster, current: current),
  );
  if (opened == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Asked the deciders to sign. It lands once they have.')));
  }
}

class _PolicyDialog extends StatefulWidget {
  const _PolicyDialog(
      {required this.service, required this.roster, required this.current});
  final PeerService service;
  final StaffRoster roster;
  final CommunityPolicy? current;

  @override
  State<_PolicyDialog> createState() => _PolicyDialogState();
}

class _PolicyDialogState extends State<_PolicyDialog> {
  late bool _operatorBound = widget.current?.operatorBoundRequired ?? false;
  late int _minTier = widget.current?.minTier ?? 0;
  late final _cap = TextEditingController(
      text: widget.current?.dailyPostCap?.toString() ?? '');
  late final Map<String, LabelAction> _labels = {
    ...?widget.current?.labels,
  };
  // What posts from other communities do, by their standing in our compacts
  // (Ethne D39). Seeded from the policy in force: leaving one out would loosen it.
  late final Map<String, LabelAction> _standing = {
    ...?widget.current?.standing,
  };
  final _newLabel = TextEditingController();
  final _rationale = TextEditingController();
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
    _cap.dispose();
    _newLabel.dispose();
    _rationale.dispose();
    super.dispose();
  }

  void _submit() {
    final cap = int.tryParse(_cap.text.trim());
    final ax = widget.service.beginPolicyAmendment(
      policy: {
        'operator_bound_required': _operatorBound,
        'min_tier': _minTier,
        'daily_post_cap': cap,
        'labels': {for (final e in _labels.entries) e.key: e.value.wire},
        if (_standing.values.any((a) => a != LabelAction.allow))
          'standing': {
            for (final e in _standing.entries)
              if (e.value != LabelAction.allow) e.key: e.value.wire,
          },
      },
      rationale: _rationale.text.trim(),
      deciderDids: _deciders.toList(),
      askPeers: askPeersOf(widget.service, _ask),
    );
    if (ax == null) {
      setState(() => _error = widget.service.lastCommunityError);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final majority = widget.roster.admitNeed;
    return AlertDialog(
      title: const Text('Propose a content policy'),
      content: SizedBox(
        width: 480,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              'The roll replaces the policy whole. Tightening it needs '
              '$majority deciders, a majority; loosening anything needs '
              '${majority + 1}. The log decides which this is when the act is '
              'recorded.',
              style: small,
            ),
            SwitchListTile(
              key: const Key('policy-operator'),
              title: const Text('Authors must be operator-bound'),
              value: _operatorBound,
              onChanged: (v) => setState(() => _operatorBound = v),
            ),
            Row(children: [
              const Text('Lowest author tier'),
              const SizedBox(width: 8),
              DropdownButton<int>(
                key: const Key('policy-min-tier'),
                value: _minTier,
                items: [
                  for (var t = 0; t <= 4; t++)
                    DropdownMenuItem(value: t, child: Text('$t')),
                ],
                onChanged: (v) => setState(() => _minTier = v ?? 0),
              ),
            ]),
            TextField(
              key: const Key('policy-cap'),
              controller: _cap,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Posts per author a day (blank = no limit)'),
            ),
            const SizedBox(height: 8),
            const Text('Labels'),
            for (final e in _labels.entries.toList())
              Row(children: [
                Expanded(child: Text(e.key)),
                DropdownButton<LabelAction>(
                  value: e.value,
                  items: [
                    for (final a in LabelAction.values)
                      DropdownMenuItem(value: a, child: Text(a.name)),
                  ],
                  onChanged: (v) =>
                      setState(() => _labels[e.key] = v ?? LabelAction.allow),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => setState(() => _labels.remove(e.key)),
                ),
              ]),
            Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('policy-new-label'),
                  controller: _newLabel,
                  decoration: const InputDecoration(
                      labelText: 'New label ([a-z0-9_-], up to 32)'),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () {
                  final l = _newLabel.text.trim();
                  if (RegExp(r'^[a-z0-9_-]{1,32}$').hasMatch(l)) {
                    setState(() {
                      _labels[l] = LabelAction.warn;
                      _newLabel.clear();
                    });
                  }
                },
              ),
            ]),
            const SizedBox(height: 8),
            const Text('Posts made in other communities, by their standing in our compacts'),
            for (final (key, label) in const [
              ('Probationary', 'probationary'),
              ('Denied', 'refused by our compact'),
              ('Anathema', 'anathema'),
              ('Outside', 'outside our compacts'),
            ])
              Row(children: [
                Expanded(child: Text(label)),
                DropdownButton<LabelAction>(
                  key: Key('policy-standing-$key'),
                  value: _standing[key] ?? LabelAction.allow,
                  items: [
                    for (final a in LabelAction.values)
                      DropdownMenuItem(value: a, child: Text(a.name)),
                  ],
                  onChanged: (v) => setState(() => _standing[key] = v ?? LabelAction.allow),
                ),
              ]),
            TextField(
              key: const Key('policy-rationale'),
              controller: _rationale,
              decoration: const InputDecoration(labelText: 'Why (recorded)'),
            ),
            const SizedBox(height: 8),
            Signers(
              service: widget.service,
              roster: widget.roster,
              need: '$majority to tighten, ${majority + 1} to loosen',
              deciders: _deciders,
              ask: _ask,
              onChanged: () => setState(() {}),
            ),
            if (_error != null)
              Text(_error!,
                  key: const Key('policy-error'),
                  style: TextStyle(color: scheme.error, fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel')),
        FilledButton(
          key: const Key('policy-submit'),
          onPressed: _deciders.length >= majority ? _submit : null,
          child: const Text('Ask deciders to sign'),
        ),
      ],
    );
  }
}

Future<void> _moderatorChange(
    BuildContext context, PeerService service, List<String> moderators) async {
  final roster = service.staffRoster;
  if (roster == null) return;
  await showDialog<bool>(
    context: context,
    builder: (_) => _ModeratorDialog(
        service: service, roster: roster, moderators: moderators),
  );
}

class _ModeratorDialog extends StatefulWidget {
  const _ModeratorDialog(
      {required this.service, required this.roster, required this.moderators});
  final PeerService service;
  final StaffRoster roster;
  final List<String> moderators;

  @override
  State<_ModeratorDialog> createState() => _ModeratorDialogState();
}

class _ModeratorDialogState extends State<_ModeratorDialog> {
  String? _holder;
  final _rationale = TextEditingController();
  final Set<String> _deciders = {};
  final Set<String> _ask = {};
  String? _error;

  @override
  void dispose() {
    _rationale.dispose();
    super.dispose();
  }

  bool get _confer => !widget.moderators.contains(_holder);

  void _submit() {
    final holder = _holder;
    if (holder == null) return;
    final ax = widget.service.beginModeratorChange(
      holderDid: holder,
      confer: _confer,
      rationale: _rationale.text.trim(),
      deciderDids: _deciders.toList(),
      askPeers: askPeersOf(widget.service, _ask),
    );
    if (ax == null) {
      setState(() => _error = widget.service.lastCommunityError);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final majority = widget.roster.admitNeed;
    return AlertDialog(
      title: const Text('Seat or unseat a moderator'),
      content: SizedBox(
        width: 480,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              'A moderator labels posts in the community\'s name alone; what a '
              'label does is the policy\'s. Seating needs a majority and the '
              'member\'s own consent; unseating needs a majority without them.',
              style: small,
            ),
            for (final m in widget.roster.members.where((m) => m.inducted))
              ListTile(
                key: Key('moderator-${m.did}'),
                dense: true,
                selected: _holder == m.did,
                leading: Icon(_holder == m.did
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title: Text(m.did, style: const TextStyle(fontSize: 12)),
                subtitle: Text(widget.moderators.contains(m.did)
                    ? 'moderates — choose to unseat'
                    : 'choose to seat'),
                onTap: () => setState(() => _holder = m.did),
              ),
            TextField(
              controller: _rationale,
              decoration: const InputDecoration(labelText: 'Why (recorded)'),
            ),
            Signers(
              service: widget.service,
              roster: widget.roster,
              need: '$majority needed',
              deciders: _deciders,
              ask: _ask,
              onChanged: () => setState(() {}),
            ),
            if (_error != null)
              Text(_error!,
                  style: TextStyle(color: scheme.error, fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel')),
        FilledButton(
          key: const Key('moderator-submit'),
          onPressed:
              _holder != null && _deciders.length >= majority ? _submit : null,
          child: Text(_confer ? 'Ask to seat' : 'Ask to unseat'),
        ),
      ],
    );
  }
}

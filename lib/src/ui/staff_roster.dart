// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The staff roll (Phase 3 P3.3, SOCIAL_APP_PLAN.md §2.2): who is in this
// business, who among them actually decides, which members are machines and who
// answers for each, and what is waiting on this node to co-sign.
//
// This screen shows states that look like faults and are not. A machine with no
// guardian is an honest chartered state — a release clears the edge and keeps
// the designation, because a machine does not become human by losing its human.
// An edge can be perfectly valid and still ungrounded, because the observation
// behind it came from inside the roll, and a polity may not vouch for its own
// ground. An attendance stamp ages, and a node bound to a guardian with nobody
// at the keyboard for a week is normal. So none of these is drawn as an error:
// they are drawn as what they are, with the reason the log gave, and the reader
// decides what to make of them.
//
// What IS drawn as a warning is a claim that does not hold up: a log that does
// not verify, and bytes that do not say what the node asking you to sign them
// says they say.

import 'package:flutter/material.dart' hide ConnectionState;

import '../model/cosign_exchanges.dart';
import '../model/staff_roster.dart';
import '../node/peer_stream.dart';
import 'expel_dialog.dart';

class StaffRosterPage extends StatelessWidget {
  const StaffRosterPage({super.key, required this.service});

  final PeerService service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Staff roll')),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final roster = service.staffRoster;
          final pending = service.pendingCosigns;
          return ListView(
            children: [
              const _RosterLegend(),
              if (roster == null) const _NoPolity(),
              if (roster != null) ...[
                _GovernanceCard(roster: roster),
                const _RollUnionNote(),
                _PublishedRollCard(service: service),
              ],
              if (pending.isNotEmpty) const _PendingHeader(),
              for (final e in pending)
                _CosignTile(exchange: e, service: service),
              if (service.authoredExchanges.isNotEmpty)
                const _AuthoredHeader(),
              for (final a in service.authoredExchanges)
                _AuthoredTile(exchange: a, service: service),
              if (roster != null)
                for (final m in roster.members)
                  _MemberTile(member: m, roster: roster, service: service),
            ],
          );
        },
      ),
    );
  }
}

class _RosterLegend extends StatelessWidget {
  const _RosterLegend();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        'The roll of the polity this node is staff of. Only inducted members '
        'carry deciding weight, so what a vote costs is counted over them and '
        'not over the roll. Every machine member answers to a named human; '
        'where one does not, that is a fact about the polity rather than a '
        'fault in it.',
        style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
      ),
    );
  }
}

class _NoPolity extends StatelessWidget {
  const _NoPolity();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      key: Key('roster-no-polity'),
      padding: EdgeInsets.fromLTRB(16, 32, 16, 16),
      child: Text(
        'This node is not staff of any polity. A business is a polity, and its '
        'roll lives in a charter log its members hold — there is none here.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13),
      ),
    );
  }
}

/// What a vote costs, whether the polity can shrink, and whether the log it is
/// all read out of actually verifies.
class _GovernanceCard extends StatelessWidget {
  const _GovernanceCard({required this.roster});

  final StaffRoster roster;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${roster.roll} on the roll · ${roster.seasoned} inducted',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(child: Text('an admission needs',
                    style: TextStyle(fontSize: 12))),
                _NeedBadge(
                  key: const Key('roster-admit-need'),
                  need: roster.admitNeed,
                  of: roster.seasoned,
                  reachable: true,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Expanded(child: Text('an expulsion needs',
                    style: TextStyle(fontSize: 12))),
                _NeedBadge(
                  key: const Key('roster-expel-need'),
                  need: roster.expelNeed,
                  of: roster.expelEligible,
                  reachable: roster.expelReachable,
                ),
              ],
            ),
            if (!roster.expelReachable)
              _Advisory(
                key: const Key('roster-expel-unreachable'),
                severe: true,
                icon: Icons.block_outlined,
                text: 'An expulsion cannot close at this size. It needs '
                    '${roster.expelNeed} deciders, and the target may not '
                    'decide its own removal, which leaves '
                    '${roster.expelEligible} eligible.',
              ),
            if (!roster.canContract)
              const _Advisory(
                key: Key('roster-cannot-contract'),
                icon: Icons.compress_outlined,
                text: 'This polity cannot shrink. Below the contraction floor a '
                    'departure would leave a body that cannot govern itself, so '
                    'departures and expulsions are refused.',
              ),
            if (roster.machineMajority)
              const _Advisory(
                key: Key('roster-machine-majority'),
                icon: Icons.memory_outlined,
                text: 'Machines are a majority of this roll — counted over the '
                    'whole roll, which asks what the polity is made of rather '
                    'than who decides in it. Every office must trace to a human.',
              ),
            const Divider(height: 20),
            Row(
              key: const Key('roster-verify'),
              children: [
                Icon(
                  roster.verified == true
                      ? Icons.verified_outlined
                      : roster.verified == false
                          ? Icons.gpp_maybe_outlined
                          : Icons.help_outline,
                  size: 16,
                  color: roster.verified == false
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    roster.verified == true
                        ? 'The log verifies. Everything above is a fold of what '
                            'it claims; this is the check that it holds.'
                        : roster.verified == false
                            ? 'THE LOG DOES NOT VERIFY. Everything above is a '
                                'fold of what it claims, and the claims do not '
                                'hold up. Do not act on these numbers.'
                            : 'The log was not checked. Everything above is a '
                                'fold of what it claims, which is not the same '
                                'as a log that holds.',
                    style: TextStyle(
                      fontSize: 11,
                      color: roster.verified == false
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Publishing a shorter roll removes nobody — surfaced rather than papered over.
class _RollUnionNote extends StatelessWidget {
  const _RollUnionNote();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('roster-union-note'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        'Publishing a shorter roll removes nobody. A departure recorded here '
        'does not retract anyone from a wider ring that has already taken this '
        'roll in, because such a ring unions rolls rather than replacing them. '
        'The as-of instant is carried as provenance for exactly that.',
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// The published roll (D26, border artifact #6). What a polity hands a compact
/// tier so its members have a real anonymous channel there — and the limits on
/// what handing it over can establish, stated where the act happens rather than
/// left for the reader to discover.
class _PublishedRollCard extends StatelessWidget {
  const _PublishedRollCard({required this.service});

  final PeerService service;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final published = service.publishedRoll;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The published roll',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'A polity can publish its roll under its own root key. That is what '
              'gives its members an anonymous channel in a wider compact, which '
              'knows about communities and their speakers but keeps no list of '
              'who belongs to them.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            if (!service.canPublishRoll)
              // Neutral. Not holding the polity's root key is the ordinary state
              // of a staff node, not a fault in it.
              const _Advisory(
                key: Key('roll-no-root-key'),
                icon: Icons.key_off_outlined,
                text: 'Only the holder of the polity’s root key can publish '
                    'its roll, and this node does not hold it. A member’s key '
                    'speaks for a member; the root key speaks for the polity.',
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const Key('roll-publish'),
                  icon: const Icon(Icons.history_edu_outlined, size: 18),
                  label: const Text('Publish the roll'),
                  onPressed: service.publishRoll,
                ),
              ),
            const SizedBox(height: 8),
            // The three D26 limits, as copy rather than as a footnote.
            Text(
              'Publishing is one-way. A compact unions rolls rather than '
              'replacing them, so a later, shorter roll cannot take back what an '
              'earlier one said.',
              key: const Key('roll-union-is-one-way'),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              'Nothing compels a polity to publish. One that never does simply '
              'gives its members no channel.',
              key: const Key('roll-nothing-compels'),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              'Nothing here delivers it. The roll is minted and checked on this '
              'node; no compact is wired up, and this button sends nothing.',
              key: const Key('roll-not-delivered'),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            if (published != null) ...[
              const Divider(height: 20),
              Row(
                key: const Key('roll-artifact'),
                children: [
                  Icon(Icons.description_outlined,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Names ${published.memberCount} member'
                      '${published.memberCount == 1 ? '' : 's'}'
                      '${published.asOf != null ? ', read from the log ${_ago(published.asOf!)}' : ''}.',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // THE TWO ANSWERS, KEPT APART. Reporting either as the other would
              // overstate what a reader knows.
              _VerdictLine(
                key: const Key('roll-publisher-proven'),
                ok: published.publisherProven,
                okText: 'Signed by the polity it names, and well-formed. This is '
                    'the whole of what a compact can establish: who is speaking, '
                    'never whether what they say is true.',
                badText: 'This roll is NOT signed by the polity it names, or is '
                    'malformed. It establishes nothing.',
              ),
              const SizedBox(height: 4),
              _VerdictLine(
                key: const Key('roll-audited'),
                ok: published.auditedAgainstLog,
                okText: 'And it matches this node’s own charter log at the '
                    'instant it was read. A compact cannot check this — it holds '
                    'no charter of ours — but the polity itself can.',
                badText: 'It does NOT match this node’s charter log. The '
                    'polity is saying something its own record does not.',
                unknownText: 'It was not checked against a charter log, so only '
                    'the publisher is established.',
              ),
              const SizedBox(height: 6),
              Text(
                'The polity is not named on its own roll: its root key already '
                'counts, and a second entry would be a repeated position in the '
                'ring. A true reading, not a gap.',
                key: const Key('roll-self-excluded'),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One verdict. Neutral when true, the error role only when a claim actually
/// fails, and a third wording for "nobody asked" — which is not a failure.
class _VerdictLine extends StatelessWidget {
  const _VerdictLine({
    super.key,
    required this.ok,
    required this.okText,
    required this.badText,
    this.unknownText,
  });

  final bool? ok;
  final String okText;
  final String badText;
  final String? unknownText;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = ok == false;
    final unknown = ok == null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          failed
              ? Icons.gpp_maybe_outlined
              : unknown
                  ? Icons.help_outline
                  : Icons.verified_outlined,
          size: 14,
          color: failed ? scheme.error : scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            failed ? badText : (unknown ? (unknownText ?? badText) : okText),
            style: TextStyle(
              fontSize: 11,
              color: failed ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _PendingHeader extends StatelessWidget {
  const _PendingHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        'Waiting on you',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// One ask to co-sign. Everything shown here is derived on THIS node from the
/// bytes the signature will cover — nothing the asking node said about them is
/// displayed as fact, because a node that chose both the bytes and the sentence
/// describing them could put a friendly sentence over a hostile act.
class _CosignTile extends StatelessWidget {
  const _CosignTile({required this.exchange, required this.service});

  final CosignExchange exchange;
  final PeerService service;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final derived = service.describeCosign(exchange);
    final unreadable = derived == null;
    final cidMatches =
        !unreadable && (derived['cid'] as String?) == exchange.cid;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (unreadable)
              const _Advisory(
                key: Key('cosign-unreadable'),
                severe: true,
                icon: Icons.gpp_maybe_outlined,
                text: 'These bytes cannot be read as the act they claim to be. '
                    'Nothing here says what you would be signing. Decline.',
              )
            else ...[
              Text(
                derived['description'] as String? ?? '',
                key: const Key('cosign-description'),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(
                'Derived here, from the bytes you would sign. The asking node '
                'sent no wording and could not have.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              _MetaChip(
                key: const Key('cosign-cid'),
                icon: Icons.tag_outlined,
                label: _short(derived['cid'] as String? ?? '—'),
              ),
              if (!cidMatches)
                const _Advisory(
                  key: Key('cosign-cid-mismatch'),
                  severe: true,
                  icon: Icons.report_gmailerrorred_outlined,
                  text: 'The content id the asker sent does not match these '
                      'bytes. The ask names one act and carries another.',
                ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const Key('cosign-decline'),
                  onPressed: () => service.declineCosign(exchange),
                  child: const Text('Decline'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('cosign-sign'),
                  onPressed: (unreadable || !cidMatches)
                      ? null
                      : () => service.signCosign(exchange),
                  child: const Text('Sign'),
                ),
              ],
            ),
            Text(
              'Declining sends nothing. A refusal is silence.',
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthoredHeader extends StatelessWidget {
  const _AuthoredHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        'Expulsions you started',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// An expulsion this node is authoring (Phase 4 P4.1): who has signed, who has
/// not, and — only once every decider has — the step that records it. The
/// reputation consequence is applied by that step and only after the log
/// re-verifies, so nothing on this card can bound anybody early.
class _AuthoredTile extends StatelessWidget {
  const _AuthoredTile({required this.exchange, required this.service});

  final AuthoredExchange exchange;
  final PeerService service;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    final counted = service.countedSignatures(exchange);
    final need = exchange.signersRequired.length;
    final missing = exchange.signersRequired
        .where((d) => !counted.any((s) => s.signerDid == d))
        .toList();
    // A community act (Phase 4) rides the same exchange as an expulsion but
    // lands differently: nothing is capped, and the new policy is published.
    final community = exchange.record == 'content_policy' ||
        exchange.record == 'office';
    final title = switch (exchange.record) {
      'content_policy' => 'Replace the content policy',
      'office' => exchange.op == 'confer'
          ? 'Seat ${_short(exchange.memberDid)} as moderator'
          : 'Unseat ${_short(exchange.memberDid)} as moderator',
      _ => 'Expel ${_short(exchange.memberDid)}',
    };
    final status = switch (exchange.status) {
      AuthoredStatus.collecting => '${counted.length} of $need signed',
      AuthoredStatus.landed when community =>
        'Recorded. The policy readers follow is republished by the node '
            'holding the community\'s root key.',
      AuthoredStatus.landed => exchange.targetPeerUuid == null
          ? 'Recorded. No peer was picked, so no standing was changed.'
          : (exchange.standingRc == 0
              ? 'Recorded. Their standing on this node is now capped.'
              : 'Recorded, but the standing could not be handed to the core '
                  '(rc ${exchange.standingRc}).'),
      AuthoredStatus.failed => 'Not recorded: ${exchange.error ?? 'refused'}',
    };
    return Card(
      key: Key('authored-${exchange.cid}'),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(status, key: const Key('authored-status')),
            if (exchange.status == AuthoredStatus.collecting &&
                missing.isNotEmpty)
              Text('Waiting on ${missing.map(_short).join(', ')}',
                  style: small),
            if (exchange.status == AuthoredStatus.collecting)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const Key('authored-complete'),
                  onPressed: service.expulsionReady(exchange)
                      ? () => community
                          ? service.completeCommunityAct(exchange)
                          : service.completeExpulsion(exchange)
                      : null,
                  child: Text(community ? 'Record it' : 'Record expulsion'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile(
      {required this.member, required this.roster, required this.service});

  final StaffMember member;
  final StaffRoster roster;
  final PeerService service;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  member.isMachine
                      ? Icons.memory_outlined
                      : Icons.person_outline,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_short(member.did),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _MetaChip(
                  key: Key(member.inducted
                      ? 'member-decides'
                      : 'member-no-weight'),
                  icon: member.inducted
                      ? Icons.how_to_vote_outlined
                      : Icons.hourglass_empty,
                  // Admitted but not inducted is a real state, not a pending
                  // one: the member is on the roll and counts for nothing in
                  // any majority until the rite completes.
                  label: member.inducted
                      ? 'decides'
                      : 'on the roll · no deciding weight yet',
                ),
                if (member.isMachine && !member.guarded)
                  // Neutral, deliberately. An unguarded machine is an honest
                  // chartered state, and colouring it as an error would say
                  // something the charter does not.
                  const _MetaChip(
                    key: Key('member-unguarded'),
                    icon: Icons.circle_outlined,
                    label: 'unguarded',
                  ),
                if (member.isMachine && member.guarded)
                  _MetaChip(
                    key: const Key('member-guardian'),
                    icon: Icons.shield_outlined,
                    label: 'answers to ${_short(member.guardianDid ?? '—')}',
                  ),
                if (member.isMachine && member.guarded)
                  _AttendanceChip(member: member),
              ],
            ),
            if (member.isMachine && member.guarded && !member.backed)
              _Advisory(
                key: const Key('member-unbacked'),
                severe: true,
                icon: Icons.gpp_maybe_outlined,
                // The reason is rendered verbatim: it is the log's own account
                // of why the edge is not grounded, and paraphrasing it here
                // would be this app deciding what the record meant.
                text: 'This edge is not grounded. '
                    '${member.reason ?? 'No reason was recorded.'}',
              ),
            if (member.isMachine && member.guarded && member.backed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Grounded by an observation from outside the roll'
                  '${member.observer != null ? ', signed by ${_short(member.observer!)}' : ''}.',
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
            // Starting an expulsion (Phase 4 P4.1). Offered only where it could
            // succeed: this node can sign for the polity, the bar is reachable,
            // and nobody expels themselves.
            if (service.canExpel &&
                roster.expelReachable &&
                member.did != service.staffIdentity?.did)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: Key('expel-${member.did}'),
                  onPressed: () => showExpelDialog(context,
                      service: service, roster: roster, member: member),
                  child: const Text('Expel…'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The attendance stamp: present, aging, or never reported. Three states, kept
/// apart — whether a machine has a human at all is durable and is the guardian
/// edge above; whether one was recently at its console is this, and it is
/// meaningless the moment it ages. Conflating them puts responsibility in the
/// wrong place.
class _AttendanceChip extends StatelessWidget {
  const _AttendanceChip({required this.member});

  final StaffMember member;

  @override
  Widget build(BuildContext context) {
    if (!member.hasAttendanceStamp) {
      return const _MetaChip(
        key: Key('member-no-stamp'),
        icon: Icons.remove,
        // Not "unattended": no stamp and a stamp of zero are one answer, and
        // neither of them means nobody answers for this machine.
        label: 'no attendance stamp',
      );
    }
    final ago = _ago(member.attestedAt!);
    if (!member.attendanceStale) {
      return _MetaChip(
        key: const Key('member-attested'),
        icon: Icons.schedule,
        label: 'confirmed present $ago',
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('member-stale-attested'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        // surfaceContainerHigh, NOT errorContainer: this may warn and must not
        // escalate on its own. A week with nobody at the keyboard is normal.
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'last confirmed present $ago · a stamp, not a verdict',
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// A one-line note. [severe] uses the error role for a claim that does not hold
/// up; everything else stays neutral, because a state the charter allows is not
/// a problem this app gets to colour as one.
class _Advisory extends StatelessWidget {
  const _Advisory({
    super.key,
    required this.icon,
    required this.text,
    this.severe = false,
  });

  final IconData icon;
  final String text;
  final bool severe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = severe ? scheme.onErrorContainer : scheme.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: severe ? scheme.errorContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 11, color: fg)),
          ),
        ],
      ),
    );
  }
}

/// `need / of`, error-coloured only where the bar cannot be reached at all.
class _NeedBadge extends StatelessWidget {
  const _NeedBadge({
    super.key,
    required this.need,
    required this.of,
    required this.reachable,
  });

  final int need;
  final int of;
  final bool reachable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: reachable ? scheme.surfaceContainerHigh : scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$need / $of',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color:
              reachable ? scheme.onSurfaceVariant : scheme.onErrorContainer,
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

/// Shorten a DID or cid for display without pretending it is the whole thing.
String _short(String s) {
  if (s.length <= 20) return s;
  return '${s.substring(0, 12)}…${s.substring(s.length - 6)}';
}

/// A coarse age. Deliberately coarse: an attendance stamp is not precise enough
/// to deserve a precise rendering.
String _ago(int epochSeconds) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final d = now - epochSeconds;
  if (d < 0) return 'just now';
  if (d < 90) return 'just now';
  if (d < 5400) return '${(d / 60).round()} minutes ago';
  if (d < 172800) return '${(d / 3600).round()} hours ago';
  return '${(d / 86400).round()} days ago';
}

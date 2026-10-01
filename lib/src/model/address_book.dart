// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// The address book (SOCIAL_APP_PLAN Phase 4, multi-device per person): the
// people this reader added on purpose, each as one record that may list several
// devices, and this reader's own other devices (siblings). The node owns the
// book (contacts.cfg.json, siblings.cfg.json); everything here is what the node
// said, and a list answer REPLACES what is held, so a removal on another device
// or in a restored backup can never linger.
//
// A record is filed under its first device's uuid. A further device joins it
// only when the record is VERIFIED and the device's cert is signed by the same
// operator key (AT FIRST_CONTACT_PLAN Phase 4); [personOf] is how the rest of
// the app treats those devices as one person.

import '../ffi/at_events_bindings.dart';

/// Where a record came from. Same order as at_first_contact.h's provenance.
enum ContactProvenance { inPerson, token, directory, sibling, area, backup }

ContactProvenance provenanceOf(int v) =>
    v >= 0 && v < ContactProvenance.values.length
        ? ContactProvenance.values[v]
        : ContactProvenance.token;

/// How a provenance reads to a person.
String provenanceLabel(ContactProvenance p) => switch (p) {
      ContactProvenance.inPerson => 'added in person',
      ContactProvenance.token => 'added by link',
      ContactProvenance.directory => 'found in a directory',
      ContactProvenance.sibling => 'from your other device',
      ContactProvenance.area => 'met at a hub',
      ContactProvenance.backup => 'restored from a backup',
    };

/// One person in the address book.
class Contact {
  Contact({
    required this.uuid,
    required this.nickname,
    required this.petname,
    required this.verified,
    required this.provenance,
    required this.addedAt,
    required this.verifiedAt,
    List<String>? devices,
  }) : devices = devices ?? <String>[];

  /// The record's first device (what the record is filed under).
  final List<int> uuid;
  String nickname;
  String petname;
  bool verified;
  ContactProvenance provenance;
  double addedAt;
  double verifiedAt;

  /// Further devices filed under this record, uuid hex, in filing order.
  final List<String> devices;

  /// The safety number the node last showed for this contact, if asked.
  String safetyNumber = '';

  String get uuidHex => hexOf(uuid);

  /// Every device of this person, the first one first.
  List<String> get allDevices => [uuidHex, ...devices];

  /// The name to show: the local petname, else their own nickname.
  String get label => petname.isNotEmpty ? petname : nickname;

  static Contact fromEvent(AtRawEvent e) => Contact(
        uuid: List<int>.of(e.uuid),
        nickname: e.fcNickname,
        petname: e.fcPetname,
        verified: e.fcVerified,
        provenance: provenanceOf(e.fcProvenance),
        addedAt: e.fcAddedAt,
        verifiedAt: e.fcVerifiedAt,
      );

  /// Take the record fields of [e], keeping the devices and safety number.
  void update(AtRawEvent e) {
    nickname = e.fcNickname;
    petname = e.fcPetname;
    verified = e.fcVerified;
    provenance = provenanceOf(e.fcProvenance);
    addedAt = e.fcAddedAt;
    verifiedAt = e.fcVerifiedAt;
  }
}

/// Another device of this reader's own, paired.
class Sibling {
  const Sibling({required this.uuid, required this.nickname, required this.addedAt});
  final List<int> uuid;
  final String nickname;
  final double addedAt;
  String get uuidHex => hexOf(uuid);
}

/// The last outcome of a backup export or import.
class BackupOutcome {
  const BackupOutcome({
    required this.kind,
    required this.path,
    this.passphrase = '',
    this.reason = '',
    this.contacts = 0,
    this.siblings = 0,
    this.added = 0,
    this.updated = 0,
    this.removed = 0,
  });

  /// [atBackupWritten], [atBackupRestored] or [atBackupRefused].
  final int kind;
  final String path;

  /// Set only when the node generated the passphrase: shown once, never kept.
  final String passphrase;
  final String reason;
  final int contacts;
  final int siblings;
  final int added;
  final int updated;
  final int removed;

  bool get refused => kind == atBackupRefused;
}

/// A refusal the node gave one of our address-book requests.
class BookRefusal {
  const BookRefusal(this.ref, this.reason);
  final String ref;

  /// at_fc_reason_t.
  final int reason;
}

/// Refs this app tags its address-book requests with.
const String refBookList = 'book';
const String refSiblingList = 'sibs';
const String refInvite = 'invite';
const String refPairInvite = 'pair';
const String refRedeem = 'redeem';
const String refSafetyNumber = 'sn';
const String refVerify = 'verify';
const String refRename = 'rename';
const String refRemove = 'remove';
const String refSiblingRemove = 'unpair';
const String refBackupExport = 'backup';
const String refBackupImport = 'restore';

/// How a refusal reads to a person.
String refusalText(int reason) => switch (reason) {
      1 => 'That is not an Agora link.',
      2 => 'The link does not verify; it may have been altered.',
      3 => 'The link has expired.',
      4 => 'The link was already used.',
      5 => 'No address to reach them was found in the link.',
      6 => 'The request was not usable.',
      7 => 'This device could not sign a link.',
      atFcReasonMismatch => 'The digits do not match. Do not mark them verified.',
      atFcReasonUnknownContact => 'They are not in your address book.',
      atFcReasonNotSibling =>
        'The two devices are not under the same operator key (or one has no device cert).',
      _ => 'Refused ($reason).',
    };

/// How a backup refusal reads to a person.
String backupRefusalText(String reason) => switch (reason) {
      'weak_passphrase' => 'The passphrase needs at least 12 characters.',
      'bad_passphrase' => 'Wrong passphrase.',
      'malformed' => 'That file is not an Agora backup.',
      'unsupported' => 'That backup was made by a newer version.',
      'io' => 'The file could not be read or written.',
      'bad_request' => 'The path must be absolute.',
      _ => 'Refused ($reason).',
    };

class AddressBook {
  /// Records by their first device's uuid hex.
  final Map<String, Contact> contacts = {};

  /// Our own other devices, by uuid hex.
  final Map<String, Sibling> siblings = {};

  /// device uuid hex -> the record it is filed under.
  final Map<String, String> _deviceOwner = {};

  /// A list answer in progress, swapped in whole at its DONE.
  Map<String, Contact>? _listing;
  Map<String, Sibling>? _siblingListing;

  /// Whether a list has ever completed; until then the book is "not loaded"
  /// rather than empty.
  bool loaded = false;

  /// The last link minted for someone to add us, and for pairing a device.
  String invitation = '';
  int invitationExpiry = 0;
  String pairInvitation = '';
  int pairInvitationExpiry = 0;

  /// The last refusal of one of our requests, for the UI to show once.
  BookRefusal? lastRefusal;

  /// The last device paired with this one (SIBLING_PAIRED), for the UI.
  Sibling? lastPaired;

  /// The last backup outcome.
  BackupOutcome? lastBackup;

  /// Set when something changed the book behind our back (a sibling sync, a
  /// pairing, a restore, a link redeemed): the next tick re-lists.
  bool needsRefresh = false;

  /// The person [uuidHex] belongs to: the record it is filed under, or itself
  /// when it is in no record.
  String personOf(String uuidHex) => _deviceOwner[uuidHex] ?? uuidHex;

  /// Every device of the person [uuidHex] belongs to (itself alone when it is
  /// in no record).
  List<String> devicesOf(String uuidHex) =>
      contacts[personOf(uuidHex)]?.allDevices ?? [uuidHex];

  /// The record [uuidHex] belongs to, if any.
  Contact? contactOf(String uuidHex) => contacts[personOf(uuidHex)];

  bool isSibling(String uuidHex) => siblings.containsKey(uuidHex);

  List<Contact> get sorted => contacts.values.toList()
    ..sort((a, b) {
      final byName = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return byName != 0 ? byName : a.uuidHex.compareTo(b.uuidHex);
    });

  void _reindex() {
    _deviceOwner.clear();
    for (final c in contacts.values) {
      _deviceOwner[c.uuidHex] = c.uuidHex;
      for (final d in c.devices) {
        _deviceOwner[d] = c.uuidHex;
      }
    }
  }

  /// Take in one [agoraEventContact] or [agoraEventBackup] event. Returns
  /// whether it was an address-book event; [consumed] says whether anything
  /// else (the hub directory) should still see it.
  ({bool handled, bool consumed}) ingest(AtRawEvent e) {
    if (e.kind == agoraEventBackup) {
      lastBackup = BackupOutcome(
        kind: e.fcKind,
        path: e.backupPath,
        passphrase: e.backupPassphrase,
        reason: e.fcReason,
        contacts: e.backupContacts,
        siblings: e.backupSiblings,
        added: e.backupAdded,
        updated: e.backupUpdated,
        removed: e.backupRemoved,
      );
      if (e.fcKind == atBackupRestored) needsRefresh = true;
      return (handled: true, consumed: true);
    }
    if (e.kind != agoraEventContact) return (handled: false, consumed: false);
    final who = hexOf(e.uuid);
    switch (e.fcKind) {
      case atFcInvitation:
        if (e.fcRef == refPairInvite) {
          pairInvitation = e.fcBlob;
          pairInvitationExpiry = e.fcExpiry;
        } else {
          invitation = e.fcBlob;
          invitationExpiry = e.fcExpiry;
        }
        return (handled: true, consumed: true);
      case atFcRefused:
        // Ours when it answers one of our address-book refs; a hub request's
        // refusal is the hub directory's.
        if (_ours(e.fcRef)) lastRefusal = BookRefusal(e.fcRef, e.fcCount);
        return (handled: true, consumed: false);
      case atFcHelloSent:
      case atFcEstablished:
        // Redeeming a link records the contact; a hub request that completes
        // does too. Either way the book changed.
        needsRefresh = true;
        return (handled: true, consumed: false);
      case atFcContact:
        final listing = e.fcRef == refBookList ? _listing ??= {} : null;
        if (listing != null) {
          listing[who] = Contact.fromEvent(e);
        } else {
          _upsert(e);
          if (e.fcOrigin != atFcOriginLocal) needsRefresh = true;
        }
        return (handled: true, consumed: true);
      case atFcDeviceLinked:
        final dev = hexOf(e.fcDeviceUuid);
        final listing = e.fcRef == refBookList ? _listing : null;
        final rec = listing != null
            ? listing[who] ??= Contact.fromEvent(e)
            : _upsert(e);
        if (dev != rec.uuidHex && !rec.devices.contains(dev)) rec.devices.add(dev);
        if (listing == null) _reindex();
        return (handled: true, consumed: true);
      case atFcContactsDone:
        if (e.fcRef == refBookList) {
          final next = _listing ?? <String, Contact>{};
          // Keep safety numbers already shown for records that survive.
          for (final c in next.values) {
            c.safetyNumber = contacts[c.uuidHex]?.safetyNumber ?? '';
          }
          contacts
            ..clear()
            ..addAll(next);
          _listing = null;
          loaded = true;
          _reindex();
        }
        return (handled: true, consumed: true);
      case atFcSafetyNumber:
        _upsert(e).safetyNumber = e.fcSafetyNumber;
        return (handled: true, consumed: true);
      case atFcVerified:
        _upsert(e);
        return (handled: true, consumed: true);
      case atFcRemoved:
        contacts.remove(who);
        _reindex();
        if (e.fcOrigin != atFcOriginLocal) needsRefresh = true;
        return (handled: true, consumed: true);
      case atFcSiblingPaired:
        final s = Sibling(uuid: List<int>.of(e.uuid), nickname: e.fcNickname, addedAt: 0);
        siblings[s.uuidHex] = s;
        lastPaired = s;
        needsRefresh = true;
        return (handled: true, consumed: true);
      case atFcSibling:
        final s = Sibling(
            uuid: List<int>.of(e.uuid), nickname: e.fcNickname, addedAt: e.fcAddedAt);
        if (e.fcRef == refSiblingList) {
          (_siblingListing ??= {})[s.uuidHex] = s;
        } else {
          siblings[s.uuidHex] = s;
        }
        return (handled: true, consumed: true);
      case atFcSiblingsDone:
        if (e.fcRef == refSiblingList) {
          siblings
            ..clear()
            ..addAll(_siblingListing ?? const {});
          _siblingListing = null;
        }
        return (handled: true, consumed: true);
      case atFcSiblingRemoved:
        siblings.remove(who);
        return (handled: true, consumed: true);
    }
    return (handled: false, consumed: false);
  }

  Contact _upsert(AtRawEvent e) {
    final who = hexOf(e.uuid);
    final held = contacts[who];
    if (held != null) {
      held.update(e);
      return held;
    }
    final c = Contact.fromEvent(e);
    contacts[who] = c;
    _reindex();
    return c;
  }

  static bool _ours(String ref) => const {
        refInvite,
        refPairInvite,
        refRedeem,
        refSafetyNumber,
        refVerify,
        refRename,
        refRemove,
        refSiblingRemove,
        refBookList,
        refSiblingList,
      }.contains(ref);
}

String hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int> bytesOfHex(String hex) => [
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ];

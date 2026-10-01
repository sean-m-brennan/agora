# One person, several devices

**Claim (Agora Phase 4; [design](design.md) §4):** a person can carry Agora on more than
one device, replace a lost one, and still be one person to everyone who knows
them.

## The model

Every device is its own AutonomousTrust node, with its own uuid and keys. No
key is shared between devices. What makes devices one person is the person's
**operator key**. It signs a device cert for each device, saying "this node is
mine". The key lives in the operator's keystore, and `tools/device_cert.py`
issues certs from there. Neither the node nor the Agora app ever holds it.
A device without a cert is a person of its own.

From that one fact, three things follow (AT FIRST_CONTACT_PLAN Phase 4):

- **Pairing.** Two devices whose certs name the same operator pair. They then
  keep one address book: every edit on one reaches the other.
- **Linking.** A contact who has *verified* you files your new device under
  your record when it announces itself. Verification carries over. Earned
  reputation does not: the new device starts from the verified seed.
- **Backup.** The address book and the paired-device list, sealed with a
  passphrase, restore onto a new device when the old one is gone. Verified
  contacts stay verified.

## What Agora treats as the person

The address book says which devices are one person. Agora reads it from the
node and rebuilds it after every restart, sibling sync and restore. An
address-book list names each further device after its record.

| | Per person | Per device |
|---|---|---|
| Roster tile | one tile, "· N devices", the address-book name | — |
| Dunbar budget | one tie; strength is the strongest device's | — |
| Tie recency | tending any device tends the person | — |
| Connection | connected on any device is connected; a connection extends to a newly linked device, and that device's request is accepted without asking | the core's edge itself |
| Block | blocking blocks every device, including one linked later; a block on any device hides all of them | the core's block entries |
| DMs | one thread; a message goes to every device that is a peer | each device's sequence numbers |
| Feed | the author is named by the address book; our own other devices read as "you · other device" | post ids |
| Hub cards | one card per person; our own devices are left out | — |
| Reputation, reports | — | each device earns and is reported on its own, as AT keeps it |
| Community post caps, business endorsements | — | counted per device |

Our own other devices are us. They never appear as peers.

## Recovering a lost device

1. Restore the operator key into the keystore: `tools/backup.py restore-key`.
2. Issue the new device its cert: `tools/device_cert.py issue`, then start
   Agora.
3. In Your devices → Restore a backup, give the file and its passphrase.

The contacts come back verified, and each one's node files the new device
under you. Pair again with your other devices to keep them in step.

## Evidence

- Unit: `test/address_book_test.dart`, `test/multi_device_test.dart`,
  `test/contacts_ui_test.dart`. In AT, the list's per-device events are
  checked in both runtimes (`test_first_contact_app_verbs.py`,
  `first_contact_app_test.c`).
- Live: `test/cohort/device_cohort.sh`. One human's three devices, a contact
  and another operator's device, each on its own routed link. A
  verified add, a refused cross-operator pairing, a pairing whose book follows,
  the contact filing the new device under the same person, a DM to the other
  device, and a lost-both restore that links a third.

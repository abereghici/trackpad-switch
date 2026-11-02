# Security

## Reporting a vulnerability

Report it privately through [GitHub Security Advisories](https://github.com/abereghici/trackpad-switch/security/advisories/new). Don't open a public issue.

Include the macOS version on both Macs, the TrackpadSwitch version or commit, the steps to reproduce, and what an attacker gains.

## Supported versions

Only the latest release receives security fixes.

## Scope

In scope: the linking protocol, command authentication and replay protection, key storage, and anything that lets a device other than the linked Mac move, release or pair the chosen device.

Out of scope: attacks that need an administrator account or physical access to an unlocked Mac, and the limits listed below.

## Security model

| Property | How | Evidence |
| --- | --- | --- |
| A Mac obeys only the Mac it was linked with | Every command carries an HMAC-SHA256 tag under a key derived with HKDF-SHA256 from the link key | [`LinkMessage.swift`](Packages/TrackpadSwitchCore/Sources/TrackpadSwitchCore/LinkMessage.swift), `testRejectsEveryFlippedBit`, `testRejectsOtherKey` |
| A relay between the Macs during linking is detected | Substituted keys give different digits on the two Macs; they match by chance once in 1,000,000 attempts | `testKeySubstitutionShowsDifferentDigits` |
| A recorded command can't be replayed | A command is accepted within 30 seconds of its timestamp, once per random 64-bit nonce | [`ReplayGuard.swift`](Packages/TrackpadSwitchCore/Sources/TrackpadSwitchCore/ReplayGuard.swift), `ReplayGuardTests` |
| A linked Mac can move only the chosen device | Commands about any other address are refused | `testRefusesRequestsAboutOtherDevices` |
| Invalid public keys are refused | Peer keys are parsed with `init(x963Representation:)`, which rejects points off the P-256 curve | `testRejectsPointNotOnCurve` |
| The link key is never sent between the Macs | Each Mac derives it from the ECDH exchange and stores it in its login keychain | `testBothSidesShowSameDigitsAndShareSecret`, [`KeychainStore.swift`](App/System/KeychainStore.swift) |

Limits:

- Replay protection is kept in memory, so a recorded command can be replayed within 30 seconds of the receiving app restarting.
- Any app on the Mac can open the `trackpadswitch://` URLs and so trigger a switch.
- The app isn't sandboxed.
- The link key is a generic password in the login keychain, so it is included wherever that keychain is backed up or migrated.



# Contributing

Bug reports and pull requests are welcome. For a security issue, follow [SECURITY.md](SECURITY.md) instead.

## Building

Requirements: Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`; CI uses 2.46.0).

```sh
cp Configs/Local.xcconfig.example Configs/Local.xcconfig   # set DEVELOPMENT_TEAM to your team ID
xcodegen generate
open TrackpadSwitch.xcodeproj
```

The Xcode project is generated from [`project.yml`](project.yml); neither it nor `Configs/Local.xcconfig` is committed.

## Checks

CI ([`ci.yml`](.github/workflows/ci.yml)) runs these on every push to `main` and every pull request, and a change must pass them:

```sh
swift format lint --strict --recursive App Packages
(cd Packages/TrackpadSwitchCore && swift test --force-resolved-versions)
xcodebuild -project TrackpadSwitch.xcodeproj -scheme TrackpadSwitch -configuration Release \
  -destination 'generic/platform=macOS' -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
```

Warnings are errors. Switching and linking decisions belong in `Packages/TrackpadSwitchCore`, with a unit test there. Changes to `App/` talk to Bluetooth hardware, so test them on two Macs and say in the pull request what you ran and on which macOS versions.

## Releasing

Releases need an Apple Developer Program membership. Store notarization credentials once:

```sh
xcrun notarytool store-credentials trackpadswitch-notary --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
```

`scripts/release.sh trackpadswitch-notary` then archives, signs with Developer ID, notarizes, staples, checks the result with `spctl`, and writes `build/TrackpadSwitch-<version>.zip` with a `.sha256` file.

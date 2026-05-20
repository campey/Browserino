# Browserino — local fork dev notes

This is `tmepple/Browserino`, a personal fork of `AlexStrNik/Browserino`. Upstream is the source of truth; this fork carries occasional cherry-picked PRs that haven't merged upstream yet.

## Merging an upstream PR

Upstream PRs can be pulled directly from GitHub's pull refs without adding a remote:

```bash
git fetch https://github.com/AlexStrNik/Browserino.git pull/<N>/head:pr-<N>-<slug>
git merge --no-ff pr-<N>-<slug> -m "Merge PR AlexStrNik#<N>: <title>"
git branch -d pr-<N>-<slug>
```

`--no-ff` preserves the PR-merge context in history even when it would fast-forward.

## Building a Release for local install

The project ships with `CODE_SIGNING_ALLOWED = NO` and a hard-coded upstream `DEVELOPMENT_TEAM`, so a CLI Release build needs several overrides. **Do not edit `project.pbxproj`** — overriding on the command line keeps future upstream merges conflict-free.

Ad-hoc signing is the right choice for a personal install on this Mac: locally-built apps have no `com.apple.quarantine` xattr, so Gatekeeper doesn't intervene, and no Apple Developer account / provisioning profile is required.

```bash
rm -rf build
xcodebuild -project Browserino.xcodeproj -scheme Browserino \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY[sdk=macosx*]=-" \
  "DEVELOPMENT_TEAM[sdk=macosx*]=" \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  build
```

Why each override is needed:
- `CODE_SIGNING_ALLOWED=YES` — overrides the project's `= NO`, which otherwise disables all signing and silently produces an unsigned bundle.
- `CODE_SIGN_IDENTITY=-` (both plain **and** `[sdk=macosx*]`) — selects ad-hoc. The SDK-conditional `"Don't Code Sign"` in the project beats a plain override, so both forms are required.
- `DEVELOPMENT_TEAM=""` (both forms) — clears the upstream author's team id so the signing system doesn't try to validate the ad-hoc identity against it.

Verify the result:

```bash
codesign --verify --verbose=2 build/Build/Products/Release/Browserino.app
# Expect: "valid on disk" and "satisfies its Designated Requirement"
```

## Installing into /Applications

Browserino is almost always running (it's the default browser), so it has to be quit before its bundle can be replaced.

```bash
osascript -e 'quit app "Browserino"'; sleep 1
rm -rf /Applications/Browserino.app
cp -R build/Build/Products/Release/Browserino.app /Applications/
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/Browserino.app
open /Applications/Browserino.app
```

The default-browser association and user preferences are keyed by bundle id (`xyz.alexstrnik.Browserino`), so they survive the replacement as long as the bundle id is not changed.

## Debug builds

For quick local iteration that doesn't touch /Applications, skip signing entirely:

```bash
xcodebuild -project Browserino.xcodeproj -scheme Browserino \
  -configuration Debug -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
# Launches from ~/Library/Developer/Xcode/DerivedData/Browserino-*/Build/Products/Debug/
```

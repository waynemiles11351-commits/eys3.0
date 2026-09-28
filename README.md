# GGD Identity Overlay v5 — checked runtime-discovery build

Target reference from the supplied game package:

- Bundle ID: `com.seayoo.ggd`
- Version: `1.1.13`
- Build: `8`
- Minimum iOS: `18.0`
- UnityFramework: arm64 Mach-O

## Why v5 is different

This build intentionally removes all hard-coded game/player memory offsets.

The supplied reference binary contains the runtime class path:

`Goose.Guidance.Tutorial` → `<Game>k__BackingField`

and the fallback:

`Adam.Gameplay.App` → `game`

It also contains the `Goose.GooseGame` class and the `players` field name. v5 uses those names through IL2CPP metadata, but obtains field/method information from the live runtime rather than assuming object offsets.

List and Dictionary values are enumerated through managed methods (`get_Count`, `get_Item`, `get_Values`, `GetEnumerator`, `MoveNext`, `get_Current`) with `il2cpp_runtime_invoke` and exception checks.

No Camera/Transform/world-to-screen access is performed in this stage.

## Build

GitHub Actions workflow: `.github/workflows/build.yml`

Artifact: `GGDIdentityOverlay-v5-arm64`

The resulting dylib is unsigned. Use the same signing/injection process as your existing test build.

## In-game test sequence

1. Launch the injected game.
2. Finish the contract/consent page normally.
3. Open the `GGD 已加载` floating button.
4. Tap `开始读取` only after reaching the game lobby/room.
5. Read the status lines.

The status deliberately distinguishes:

- IL2CPP API discovery
- Game instance discovery
- GooseGame discovery
- `players` Dictionary discovery
- Dictionary enumeration
- player name/faction/career field discovery

Do not treat `ID=n` as a localized role name yet. It is the real observed runtime integer, which is used to build a version-specific role map in the next stage.

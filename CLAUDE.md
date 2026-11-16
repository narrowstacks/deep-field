# Deep Field

macOS menu bar app (Swift, SwiftPM, Metal) that draws animated, pixel-dithered space scenes as
the desktop wallpaper. `docs/DEVELOPMENT.md` covers the code layout, how rendering works and the
dev command line; read it before touching rendering or adding a scene.

## Build and check

- `./build.sh` makes `build/DeepField.app`; `swift build -c release` is the quick compile.
- Shaders are Metal source in Swift strings, compiled when the app starts, so a clean build says
  nothing about them. Render a snapshot of every scene you touched to prove the shader compiles
  and looks right:
  `.build/release/DeepField --snapshot out.png --defaults --scene <kind> --size 1720x720 --time 300`
- The `.build/release` binary needs `DYLD_FRAMEWORK_PATH=$PWD/.build/out/Products/Release` for
  Sparkle. macOS strips `DYLD_*` when it passes through `/bin/sh` or a shim (xargs, pyenv), so set
  it on the line that runs the binary, or render with `build/DeepField.app` instead.
- Scene events fire even with `--no-events` (that flag only stops the shared sky events). Pick a
  calm time with `--list-events`, or force one with `--demo <id>:<start>`.
- `--benchmark --defaults --scene <kind>`: keep frame GPU time under about 2 ms.

## Adding a scene

Copy the shape of an existing one, for example the Gas Giant Storms commit (`git log --grep
"Gas Giant Storms scene"`): a `Shader<Name>.swift` file, its `SceneKind` case, renderer entries,
`SceneParams` builder, config fields, event `Kind`, and the Customize UI. `shaderIndex` and event
ids must be unique; check the existing ones.

- Use `sq(x)` for squares. Metal's `pow(x, 2.0)` is undefined for negative `x` and once blacked
  out half a scene; keep the base of any other `pow` non-negative.
- Picked colors go through `Tuned` and `PickedColor` so a pick shows as picked.
- A scene can add or subtract glow with `SceneKind.extraBloom`.

## Look and feel

What the owner has consistently asked for: soft edges and gradual falloff (no hard cut-offs or
crisp outlines), saturated and varied color, visible motion in real time, and flashes and
twinkles used sparingly. Ground scenes in real physics, tuned for looks.

## Releasing

1. Write user-facing notes under `## [Unreleased]` in `CHANGELOG.md` as you go.
2. To ship: set `VERSION`, rename `Unreleased` to `## [x.y.z] - <date>` (CI checks a section
   exists for `VERSION`), commit, push `main`, then push an annotated tag:
   `git tag -a vx.y.z -m "Deep Field x.y.z" && git push origin vx.y.z`.
3. The Release workflow builds, signs, notarizes and publishes on the self-hosted Mac runner;
   installed copies update through Sparkle.
4. The workflow then pushes an empty `[deploy]` commit to narrowstacks/deep-field-website so it
   rebuilds with the release (needs the `WEBSITE_DEPLOY_TOKEN` secret). If that step fails, push
   `chore: ship Deep Field x.y.z [deploy]` there by hand.

## Writing

Never use the em dash character anywhere (code, comments, docs, commits). Comments explain the
physics and the reason for a choice, in a sentence or two.

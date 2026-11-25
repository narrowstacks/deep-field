# Contributing to Deep Field

Bug reports, ideas and pull requests are welcome.

## Build and check

```bash
./build.sh
build/DeepField.app/Contents/MacOS/DeepField --check-customization
build/DeepField.app/Contents/MacOS/DeepField --check-schedule
```

If you changed a scene or a shader, also render a snapshot of it, since shaders compile only when
the app runs, and add before and after images to the pull request.
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) covers the rest.

## Changelog and credit

Add a line about what changed for users under `## [Unreleased]` in [`CHANGELOG.md`](CHANGELOG.md),
in the same pull request. Contributors are credited there, and so in the release notes, by GitHub
username: end the line with `Thanks to @username ([#22](link to the pull request)).` Once the pull
request has a number, fill it in, or the maintainer will. People who report a bug or suggest a
feature in an issue are credited the same way.

## License agreement

Before your first pull request is merged, you'll be asked to sign the
[Contributor License Agreement](CLA.md) with a comment on it.

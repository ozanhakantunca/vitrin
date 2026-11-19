# Contributing

Install macOS 13 or later and the Command Line Tools (`xcode-select --install`), then clone the repository. Build and test with:

```sh
swift build
swift test
scripts/build-app.sh
```

When working in parallel, use a separate scratch directory to avoid build locks, for example `swift build --scratch-path .build-yourname` and `swift test --scratch-path .build-yourname`.

Write clear, idiomatic Swift. Mark UI code `@MainActor`; keep private API wrappers in `Sources/Private` (and their C declarations in `Sources/PrivateC`).

Open an issue to discuss substantial changes, then submit a pull request describing the change and its tests. Keep changes focused and address review feedback. Contributions are accepted under GPL-3.0-only: inbound licensing matches the project's outbound license.

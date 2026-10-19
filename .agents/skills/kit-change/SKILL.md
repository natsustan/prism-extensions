---
name: kit-change
description: Add what an extension needs but the Prism extension protocol or PrismExtensionKit lacks — a new list field, action kind, widget template, preference type, capability, or Kit API — across the Prism repo (protocol, Kit, host) and this repo, in the right order. Use when an extension feature cannot be built with the published Kit.
---

# Change the Kit for an extension

The protocol, the Swift runtime, and `PrismTestHost` live in the Prism
repository (`~/projects/prism/Packages/PrismExtensionKit`); Prism itself
(the host) draws what the protocol describes. This repository only consumes
published Kit versions. Never work around a missing feature inside one
extension, and never add per-extension code to Prism.

## Before changing anything

- Confirm the feature is really missing: read the Kit README and
  `Sources/PrismExtensionProtocol/` in the Prism repo.
- Design it as a general protocol feature another extension could use, and
  settle its shape (names, optionality, defaults) before publishing:
  published tags never move.
- Keep it additive: a new optional field or method, older replies still
  decoded, older extensions still working. A newer extension on an older
  Prism should degrade, not fail, where possible.

## Order of work

1. **Prism repo, on a branch.** Add the types in `PrismExtensionProtocol`,
   the Swift API in `PrismExtensionKit` (with a default implementation for
   new protocol methods), recording in `PrismTestHost` if extensions need to
   assert on it, Kit tests, the Kit README's protocol section, and the host
   side in `PrismApp` through the generic extension views and
   `ExtensionHost`. Follow that repo's `AGENTS.md`, run
   `swift test --package-path Packages/PrismExtensionKit` and
   `bash script/verify.sh`.
2. **This repo, against the local Kit.** Build and test the extension with
   `PRISM_KIT_PATH=~/projects/prism/Packages/PrismExtensionKit`, and try it in
   Prism Dev built from that branch. Adjust the Kit while both are fluid.
3. **Merge the Prism PR**, then publish the Kit from the Prism repo:
   `bash script/publish_kit.sh <version>` (dry run), then with `--push`.
   Minor version for new protocol or API, patch for fixes.
4. **Point the extension at it.** Set `from: "<version>"` in its
   `Package.swift`, run `swift package --package-path extensions/<folder> update`,
   then `bash tools/check.sh extensions/<folder>` without `PRISM_KIT_PATH`.
   If `tools/` reads the new fields (index, lint, pack), bump its
   `Package.swift` too.
5. **Release the extension** with `release-extension`. Merge it only after
   the Kit version it needs is published, or CI and the release fail to
   resolve it.

## Users on an older Prism

A Gallery extension can run on a Prism that predates the new field. If the
feature is essential, set `minPrism` in the manifest to the first Prism
version that supports it; otherwise make the extension work without it.

# Agent notes

This repo is public. Keep releases, docs, and commits generic: no personal
hosts, IP addresses, servers, or e-mail addresses.

- Pipeline logic lives in `scripts/build.sh`. Its header lists the
  subcommands and the variables for a local run (`NO_GH=1 NO_CLAUDE=1`).
- Hardware facts and port rules: `docs/hardware/README.md`. It overrides the
  third-party files beside it.
- Build with PlatformIO 6.1.18. Version 6.2.0 fails with
  `SCons.Tool.FortranCommon`.
- Security model of the CI: `README.md`, section "Security model of the
  automation". A change to `scripts/claude.sh`, `scripts/secret_scan.py`, or the
  workflow triggers must keep every point of that section true.
- Checks: `actionlint`, `shellcheck -x scripts/*.sh`,
  `scripts/test-secret-scan.sh`. The `lint` workflow runs them on each push.

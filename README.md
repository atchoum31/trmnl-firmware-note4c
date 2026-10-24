# TRMNL firmware for the Zectrix NOTE4C

Unofficial community build of the [TRMNL firmware](https://github.com/usetrmnl/trmnl-firmware) for the Zectrix NOTE4C (ESP32-S3, 16 MB flash, four-color 4.2 inch e-paper). This project is not affiliated with TRMNL or Zectrix.

This repository holds patches, not a fork. The port comes from [LitoMore/trmnl-firmware](https://github.com/LitoMore/trmnl-firmware) (tag `zectrix-v1.8.10`). Many thanks to LitoMore for the original work.

Supported device: Zectrix NOTE4C only. The NOTE4 is not supported by this base.

Releases are not tested on hardware by the automation. Flash at your own risk.

## What is in this repository

- `patches/`: a `git format-patch` series that adds the NOTE4C (PlatformIO env `zectrix_note4c`).
- `patches/BASE`: the upstream ref the series applies to.
- `scripts/` and `.github/workflows/build.yml`: the automation that builds releases.
- `LICENSE`: GPL-3.0, the same license as upstream.

## Corresponding source

Each binary is built from the upstream tag named in the release plus the `patches/` in this repository at the commit named in the release notes. That commit is the corresponding source for the release. Both values are in the release notes body.

## How releases are made

A workflow runs every day. It reads the latest upstream release and checks whether the release `<tag>-note4c` exists here. If it does not, the workflow:

1. Checks out the upstream tag and applies `patches/` with `git am -3`.
2. If a patch conflicts, asks Claude to resolve the conflicts. It then builds with PlatformIO. If the build fails, it allows one more fix round.
3. Scans the result for the CI secret, regenerates `patches/` on the new upstream tag, and commits them to `main`.
4. Publishes the release `<tag>-note4c` with `SHA256SUMS`.

A release with automatic conflict resolution is marked as a pre-release. A release where the patches applied cleanly is a normal release. The existence of the release is the only record that a tag is done. A rerun after a crash starts from these facts again.

Release assets:

- `zectrix-note4c-<tag>-merged-firmware.bin`: complete flash image. Flash it at `0x0`.
- `zectrix-note4c-<tag>-firmware.bin`: app image only. It sits at `0x20000` in the merged image. Do not flash it at `0x0`.
- `SHA256SUMS`

## How to flash

You need [esptool](https://github.com/espressif/esptool) and a USB cable. Use the port name of your system in place of `PORT`.

1. Check the checksum of the file you downloaded against `SHA256SUMS`.
2. Back up the full 16 MB flash of the device first. Keep this file safe, it is your way back.

   ```sh
   esptool --chip esp32s3 --port PORT read-flash 0 0x1000000 note4c-original-16mb.bin
   ```

3. Write the merged image at `0x0`.

   ```sh
   esptool --chip esp32s3 --port PORT write-flash 0x0 zectrix-note4c-<tag>-merged-firmware.bin
   ```

4. Restart the device and finish the Wi-Fi setup on its captive portal.
5. Point the device at a TRMNL server. This can be trmnl.com or any BYOS (bring your own server) that implements the TRMNL device API.

To go back, write your backup at `0x0` the same way.

## Security model of the automation

- Only the `schedule` and `workflow_dispatch` triggers exist. No pull request, issue, or comment can start a run.
- The secret `CLAUDE_CODE_OAUTH_TOKEN` is in the environment of the Claude steps only. Claude runs with `dontAsk` mode, an allow list (file tools and read-only `git diff`, `status`, `log`, `show`), and a deny list (network, MCP, `git push`, `git remote`, `git config`, `curl`, `wget`).
- Claude runs in a throwaway Docker container that sees only the firmware checkout and the read-only hardware notes in `docs/hardware/`. Its output is not written to the public job log.
- Right after each Claude step, the diff, the commit messages, and every file of the checkout are scanned for the token in clear text, base64, and hex. A match fails the run and prints nothing of the match.
- The build job has read-only permissions. A separate job holds `contents: write` and only commits the generated patches and creates the release. Failures open or update an issue that has only the run URL.

## Setup for a fork

A maintainer must add the repository secret `CLAUDE_CODE_OAUTH_TOKEN` (Settings, Secrets and variables, Actions). Create the token with `claude setup-token`, and paste it from an interactive terminal or the web UI: a non-interactive shell stores an empty value. Then run the `check-secret` workflow, which reports whether the secret is set without showing it. Without it, the workflow still builds when the patches apply cleanly. It fails at the Claude step when a conflict needs resolving.

To run the scripts on your machine, see the header of `scripts/build.sh`. For example, this applies the patches on an upstream tag and stops at the first conflict:

```sh
TAG=v1.8.17 NO_GH=1 NO_CLAUDE=1 ./scripts/build.sh prepare
TAG=v1.8.17 NO_GH=1 NO_CLAUDE=1 ./scripts/build.sh apply
```

## License

GPL-3.0, as upstream. See `LICENSE`.

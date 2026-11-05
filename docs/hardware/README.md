# Zectrix NOTE4C hardware reference

Read this before you resolve a conflict in the Zectrix port. The port must keep
working on the NOTE4C after every upstream change.

## Target device

- Zectrix NOTE4C, ESP32-S3 N16R8 (16 MB flash, 8 MB PSRAM).
- 4.2-inch e-paper, 400×300, four colors: black, white, yellow, red.
- A full refresh takes more than ten seconds. This is normal.
- The port in `patches/` drives the panel through `bb_epaper` with the
  `EP42YR_400x300` profile. This path is the one proven on the device. Do not
  replace it with another driver or a native SSD2683 sequence.
- The firmware maps any PNG to the four panel colors itself.

## Facts the port depends on

| Function | GPIO | Notes |
| --- | --- | --- |
| Battery power latch | 17 | Must stay HIGH, also held in deep sleep, or the board loses power and cannot wake |
| Power LED | 3 | Active LOW. Driven by the ULP charge-LED program, see below |
| Charging status | 2 | Active LOW, open drain, needs the pull-up. LOW while the battery charges |
| Charge complete | 1 | Active HIGH. HIGH when the battery is full on USB |
| OK button | 0 | Active low. The only button the TRMNL firmware uses. Wakes from deep sleep |
| UP button | 39 | Active low. Not an RTC GPIO, so it cannot wake from deep sleep |
| DOWN / power button | 18 | Active low. Shares the power-button line. Armed as an ext1 wake source in `zectrix_prepare_deep_sleep()`: a press shows the next screen, like OK |

The port puts its board code under `#if defined(BOARD_ZECTRIX)`,
`BOARD_ZECTRIX_NOTE4` and `BOARD_ZECTRIX_NOTE4C` blocks, in `include/config.h`,
`src/DEV_Config.h`, `src/display.cpp`, `src/bl.cpp`, `src/main.cpp`,
`src/power.cpp` and `src/firmware_update.cpp`, plus the new files
`include/zectrix.h`, `src/zectrix.cpp`, `scripts/extra/post_build_zectrix.py`
and `sdkconfigs/sdkconfig.defaults.zectrix`. Upstream moves files between
releases (for example `src/power.cpp` became `src/power/power.cpp`). When a
file moved, put the Zectrix code in the new location. Keep every Zectrix block
when you merge upstream changes, and keep the NOTE4C on the same draw path as
`BOARD_TRMNL_4CLR`.

## Frame buffer format

`zectrix_note4c_update()` sends 100 bytes per row (2 bpp, `00` black, `01`
white, `10` yellow, `11` red). When upstream draws in 1-bpp mode
(`BB_MODE_1BPP`: message screens, G5 and BMP images), it expands each row
first. Keep this conversion. Upstream message layouts assume an 800x480 panel:
check that a new or moved message still fits 400x300.

## Charge LED

`src/zectrix.cpp` loads a ULP-FSM program at boot. It runs every 500 ms, also
in deep sleep:

- GPIO2 LOW (charging): the LED blinks.
- GPIO1 HIGH (charge complete): the LED stays on.
- Else (on battery): the LED stays off.

Keep these rules when you merge upstream changes:

- GPIO1, GPIO2 and GPIO3 stay in RTC mode. Do not call `pinMode`,
  `digitalRead`, `digitalWrite` or `rtc_gpio_hold_en` on them. Read the charger
  through `zectrix_is_charging()` and `zectrix_is_charged()`.
- `zectrix_prepare_deep_sleep()` keeps `ESP_PD_DOMAIN_RTC_PERIPH` on.
- `sdkconfigs/sdkconfig.defaults.zectrix` keeps the `CONFIG_ULP_COPROC_*`
  lines.

## OTA

OTA is on for the Zectrix targets. `src/services/firmware_update.cpp` passes
the download through `ZectrixImageCheck` (`src/zectrix.cpp`) and calls
`Update.abort()` when the image does not contain `ZECTRIX_IMAGE_ID`. Keep this
check on every OTA download path when you merge upstream changes. Do not
disable OTA, and do not change `ZECTRIX_IMAGE_ID`: devices in the field refuse
an image without the exact ID. `build.sh assets` fails when the app image lacks
the ID.

## Build

- PlatformIO env `zectrix_note4c`.
- PlatformIO 6.1.18. Version 6.2.0 fails with `SCons.Tool.FortranCommon`.

## Third-party references (MIT)

These files describe the Zectrix NOTE4 board family. Some facts differ on the
NOTE4C (panel and colors). The table above wins over them.

- `itopinion/`: copied from https://github.com/itopinion/zectrix-note4-epd-demo
  at `ca285c98ed0641f86780edb1f5ec77b0335fe649`. License in `itopinion/LICENSE`.
- `tinnci/`: copied from https://github.com/Tinnci/zectrix-note4-platform at
  `d4711d4d15627f46443bcca298ff6bbb952e74ca`. License in `tinnci/LICENSE`.

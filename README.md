# HG Deploy

A replacement for MDS (Mac Deploy Stick) for **Intel Macs**: one SSD with every
macOS installer from High Sierra to Tahoe, and a window that opens in Recovery,
recognizes the Mac, and erases and installs the newest macOS it supports.

## Using a drive

1. Plug the drive into the Intel Mac and start it in Recovery (hold ⌘R, or ⌥⌘R
   for Internet Recovery).
2. Open **Utilities ▸ Terminal** and type `/Volumes/HGDeploy/run`.
3. HG Deploy opens with the Mac's model, serial and the newest macOS it can run,
   already selected. Pick the disk, optionally an account, and click
   **Erase & Install**. The Mac restarts by itself and finishes installing.

Logs are written to the drive in `HGDeploy/Logs/<serial>_<date>.log`.

## Building drives — HG Deploy Builder

The Builder (SwiftUI, macOS 14+) runs on any Mac. It opens with an **HG SSO
sign-in** (sso.hgcellular.com, app slug `hgdeploy`); only users granted HG
Deploy in the SSO admin console get in, and a revoked or de-granted account is
signed out within 30 minutes. It updates itself from the public
[hoods-goods/hg-deploy-releases](https://github.com/hoods-goods/hg-deploy-releases)
repo (the update must be signed by our Developer ID team and notarized).

- **Drive**: erase an external SSD and set it up, or update HG Deploy on an existing drive.
- **Installers**: download installers straight from Apple's software catalog
  (High Sierra → Tahoe), update old ones, import an `Install macOS….app` or
  `InstallAssistant.pkg`, remove ones you don't need. Apple's `installer` runs
  once per batch behind a single administrator prompt.
- **Setup Defaults**: the account, computer name and SSH settings HG Deploy
  shows in Recovery (each can be changed per Mac there).

## How it works

| Piece | What it is |
|---|---|
| `Deploy/` | **HG Deploy.app**, the Recovery window. Objective-C/AppKit, x86_64, macOS 10.11+, because old Recoveries have no Swift runtime. Reads the model with `sysctl`, looks it up in `Shared/models.json` (every Intel Mac from 2009 on, with the oldest and newest macOS it runs), erases with `diskutil`, installs with the installer's own `startosinstall`. |
| `FirstBoot/` | **HGFirstBoot.pkg**, passed to `startosinstall --installpackage`. HG Deploy saves the per-Mac settings in NVRAM (`com.hgcellular.deploy`); the package's postinstall skips Setup Assistant when an account is wanted, and a one-shot LaunchDaemon creates the account (`sysadminctl`), sets the computer name, turns on SSH and automatic login, wipes the NVRAM value, removes itself and restarts. |
| `Sources/BuilderKit` | Apple catalog parsing, drive layout, installer metadata (tested). |
| `Sources/HGDeployBuilder` | The Builder UI. |
| `Shared/models.json` | Model → oldest/newest macOS. Tahoe 26 is the last macOS for Intel, so this list is complete. |

### Drive layout

```
/Volumes/HGDeploy/
  run                      launcher typed in Recovery
  READ ME.txt
  Installers/              Install macOS <name> <version>-<build>.app
  HGDeploy/
    HG Deploy.app
    HGFirstBoot.pkg
    config.json            defaults (Setup Defaults tab)
    installers.json        exact versions/builds of the installers
    Packages/              optional extra .pkg files (product archives) installed with macOS
    Logs/
```

## Building and releasing

`ci/build-app.sh` builds everything on a Mac with Xcode; GitHub Actions runs it
on the hoods-goods Mac mini, then `ci/sign.sh` and `ci/notarize.sh` sign and
notarize. Bump `VERSION` on main to publish a release: the signed `.pkg` goes to
the public `hoods-goods/hg-deploy-releases` repo (this code repo stays private)
and this repo gets the matching `v<VERSION>` tag.

Repo secrets: `MAC_CERTS_P12`, `MAC_CERTS_P12_2`, `MAC_CERTS_PASSWORD`,
`NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` (Developer ID; copy them with
refurb-station-app's *Copy signing secrets* workflow), `HGDEPLOY_SSO_SECRET` (the
`hgdeploy` app secret from HG SSO, baked into the Builder's Info.plist at build
time) and `RELEASES_TOKEN` (fine-grained token for hg-deploy-releases, Contents:
Read and write). Releases are refused if any of them is missing.

## License

Proprietary. © Hoods Goods LLC, all rights reserved. See [LICENSE](LICENSE).

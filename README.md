# LocalNook fan helper: corresponding source

This is the source code of `com.localnook.app.fan-helper`, the small root
program that ships inside LocalNook.app (in
`Contents/Library/LaunchServices/`). It is a program of its own, separate from
the LocalNook app, and it is free software under the GNU General Public
License, version 3 or (at your option) any later version. This tree is its
complete corresponding source, with the scripts that build it, so that you can
read it, build it, check it against the copy you were given, change it and pass
it on under the same licence.

`PROVENANCE` says exactly which commit of LocalNook's repository this tree was made
from, and `MANIFEST.sha256` has the SHA-256 of every file in it.

## What the helper is, and what it does

LocalNook is a macOS notch utility. Everything it does runs as you, except two
things that need root, which the helper does and nothing else does:

- **Fan control.** It reads the Mac's fan speeds and chip temperatures from the
  sensor controller (AppleSMC) and, when you ask the app to, sets a fan's mode
  and target speed. It writes only the fan keys `F<n>Md`/`F<n>md`, `F<n>Tg`
  and `Ftst`. It gives the fans back to macOS when the app stops sending its
  heartbeat (a 7 second lease), before sleep, when the chip stays at 95 degrees
  Celsius or more, on serious thermal pressure, when the sensors stop
  answering, and whenever another app takes a fan over.
- **Keeping the Mac awake with the lid closed** (opt-in). It runs
  `/usr/bin/pmset disablesleep 1` and `disablesleep 0`, and nothing else, and
  keeps a record file so a helper that dies while holding can undo it.

It starts at boot and when launchd gets a message for it, serves five XPC calls
(`status`, `apply`, `heartbeat`, `restore`, `sleepHold`), and exits after ten
idle seconds. The app and the helper each have their own types for the fans'
messages and agree only on the bytes: small JSON messages of at most 4096 bytes
(`Sources/LocalNookShared/` is what they both link). The wire, revision 3, is
written down as text in
`Sources/LocalNookShared/HelperWireContract.swift`, which both programs check
themselves against. That file is published here exactly as the app has it.

## What is in this tree

| Path | What |
| --- | --- |
| `Sources/LocalNookFanHelper/` | The helper: `main.swift` and the controllers, the SMC writer, the sleep hold, the launchd job check, and its self-test |
| `Sources/LocalNookSMC/` | The library only the helper links: the SMC reader, the thermal catalog, the helper's calls |
| `Sources/LocalNookShared/` | Code the helper and the app both link: the code-signing pin, the wire's cap and revision, the sleep hold's messages, the wire contract |
| `Resources/com.localnook.app.fan-helper.plist` | The launchd job |
| `Package.swift` | The package: three targets and the `LocalNookFanHelper` executable. Generated from LocalNook's own package declarations |
| `build-helper.sh` | Builds, strips and signs the helper the way LocalNook's release script does |
| `mpl/` | `ElevatedWindowSpace.swift`, a file of the LocalNook app under the Mozilla Public License 2.0, with its licence. Not part of the helper; see `mpl/README.md` |
| `LICENSE`, `LICENSES/`, `NOTICE` | Licence texts and who owns what |
| `PROVENANCE`, `MANIFEST.sha256` | Where this tree came from, and a checksum of every file |

The LocalNook app itself is not in this tree and is not free software; it
talks to this program over XPC and links none of its code.

## Licences

| Part | Licence |
| --- | --- |
| `Sources/LocalNookFanHelper/`, `Sources/LocalNookSMC/` | GPL-3.0-or-later (`LICENSE`). Portions adapted from Vorssaint, GPL-3.0-or-later |
| `Sources/LocalNookShared/` | MIT (`LICENSES/MIT-LocalNookShared.txt`) |
| SMCKit's and Stats' layouts and lists inside the helper's files | MIT (`LICENSES/MIT-SMCKit.txt`, `LICENSES/MIT-Stats.txt`) |
| `mpl/ElevatedWindowSpace.swift` | MPL-2.0 (`mpl/MPL-2.0.txt`) |

`NOTICE` has the copyright lines and the credits.

## Requirements

macOS 15 or later, and a Swift 6.2 toolchain: the Xcode Command Line Tools
(`xcode-select --install`) are enough. No package dependencies, no network, no
other tool beyond what ships with macOS.

## Build it

```sh
./build-helper.sh
```

This runs `swift build -c release --arch arm64 --product LocalNookFanHelper`,
copies the result to `build/com.localnook.app.fan-helper`, removes its debug map
(`strip -S`), signs it as `com.localnook.app.fan-helper` with the hardened
runtime and no entitlements, checks the signature, and checks that the launchd
job in `Resources/` is the one the helper accepts. It installs nothing and
never uses `sudo`. `./build-helper.sh --help` lists the options (a debug build,
a signing identity, a different output folder).

By default the helper is signed ad hoc. An ad-hoc helper builds, passes its
self-test, and does not listen: see "What the helper will serve" below.

To build without the script, `swift build -c release --product
LocalNookFanHelper` leaves the program in `.build/release/LocalNookFanHelper`.

## Check it works: the self-test

```sh
./build-helper.sh --self-test
# or, on any build:
build/com.localnook.app.fan-helper --self-test
```

The self-test needs no root and touches no fan, no `pmset`, no sleep setting
and no file outside a temporary folder: the controllers run against stand-ins,
and the XPC round trip stays inside the process. It ends with a line like
`helper self-test: N passed` and exits 0, or lists each failed check with a
`✗` and exits 1. Among its checks is the wire contract: the helper's encoder
and decoder against the texts in `HelperWireContract.swift`, and the helper
reporting revision 3.

## Compare it with the helper shipped in LocalNook.app

The shipped helper is at
`LocalNook.app/Contents/Library/LaunchServices/com.localnook.app.fan-helper`,
and `PROVENANCE` names the LocalNook version this tree matches. To see whether a
build of this tree is the same program as the one you were given, compare the
code and leave the signatures out of it, since a signature is made with a key
you do not have:

```sh
APP=/path/to/LocalNook.app
SHIPPED="$APP/Contents/Library/LaunchServices/com.localnook.app.fan-helper"
WORK="$(mktemp -d)"
cp "$SHIPPED" "$WORK/shipped"
cp build/com.localnook.app.fan-helper "$WORK/mine"
codesign --remove-signature "$WORK/shipped" "$WORK/mine"
shasum -a 256 "$WORK/shipped" "$WORK/mine"
```

A rebuild in the same folder, with the same Swift toolchain on the same macOS,
gives the same bytes this way. A build in a folder with another path, or with
another toolchain, can differ by a few dozen bytes (the Mach-O UUID is one)
without being a different program, and the shipped helper was built inside
LocalNook's whole package rather than this one. So if the hashes differ, compare
what the program is made of: the sizes, the symbol names (`nm`), the strings
(`strings -a`) and `codesign -dv --verbose=4` on both. Two builds of this tree
in different folders have the same size and the same symbol names. This
tree's wire revision is `HelperWire.revision` in
`Sources/LocalNookShared/HelperWire.swift`.

## Install and remove it by hand

This replaces any helper already installed, including the one LocalNook.app
installed for you; the app's own Install/Update helper row does the same with
one administrator prompt. Everything below runs as root, so read it first.
These steps reach the same result as the app's installer, with fewer
safeguards. The app also waits (up to 10 seconds) for the old job to leave
launchd; copies the program and the job to `.new` files beside their
destinations, under `umask 077`, makes them root's and clears their extended
attributes before checking anything; checks the program's signature there
against the certificate it is pinned to (a build of your own would fail that
check, which is why it is not here) and the job with the newly installed
program, each before it is moved into place; and, if any step fails, removes
the `.new` files and loads the job that was there before. Here the job is
checked as it is in `build/`, before it is copied, where the app checks the
root-owned copy it is about to move into place.

```sh
LABEL=com.localnook.app.fan-helper
# 1. Stop a copy that is running (it hands the fans back and restores sleep).
sudo launchctl bootout system/$LABEL 2>/dev/null
# 2. Put the program and its job where launchd expects them, owned by root.
sudo mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons
sudo install -o root -g wheel -m 755 build/$LABEL /Library/PrivilegedHelperTools/$LABEL
# 3. Have the installed helper confirm the job is exactly the one it accepts.
/Library/PrivilegedHelperTools/$LABEL --verify-plist build/$LABEL.plist
sudo install -o root -g wheel -m 644 build/$LABEL.plist /Library/LaunchDaemons/$LABEL.plist
# 4. Load it.
sudo launchctl enable system/$LABEL
sudo launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist
```

To remove it:

```sh
LABEL=com.localnook.app.fan-helper
sudo launchctl bootout system/$LABEL
# On this SIGTERM the helper hands the fans back to macOS and restores sleep,
# then deletes its record. If the record is still there, sleep may still be
# disabled; see below before deleting anything.
ls -l /Library/PrivilegedHelperTools/$LABEL.sleep-hold
sudo rm -f /Library/LaunchDaemons/$LABEL.plist /Library/PrivilegedHelperTools/$LABEL
```

If that record file remains after the helper is gone, run
`sudo pmset disablesleep 0`, confirm with
`ioreg -r -c IOPMrootDomain -d 1 | grep SleepDisabled` that it reads `No`, and
only then delete the record.

## What the helper will serve

The helper accepts connections only from a program signed with the identifier
`com.localnook.app` by the very same certificate the helper itself is signed
with (`identifier "com.localnook.app" and certificate leaf = H"<sha1 of its own
certificate>"`), checked before any message is read. Each side of the pair reads
its own certificate from its own signature at run time; nothing is compiled
in. So:

- A helper built here and signed ad hoc has no certificate, builds, passes its
  self-test and never listens.
- A helper you sign with your own certificate serves an app signed by that same
  certificate, and not the LocalNook.app that was signed with the author's.
  Because of that, replacing the shipped helper with a build of your own does
  not give the shipped app a working helper: the app and the helper each
  refuse a peer signed by another certificate.

The wire is the same either way, so a program you write that speaks it (the
texts in `Sources/LocalNookShared/HelperWireContract.swift`) can be the other
end.

## Changing it

The helper's behavior is pinned down by its self-test, and its wire, its
identity (label, Mach service name, revision 3) and the keys it may write are
checked on every build; change them only on purpose. Running a modified helper
as root on a real Mac writes to its fan controller and its power settings: try
changes under `--self-test` first, and keep a way to run
`sudo pmset disablesleep 0` and to restart the Mac.

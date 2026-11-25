# FixDICOM for IsiX and Horos (macOS)

Repairs DICOM files whose last **Sequence Delimitation Item** is missing (a Siemens export quirk:
DCMTK reports *"Sequence Delimitation Item missing"*) and imports the study into the database of
**IsiX DICOM Viewer** or **Horos**, in one step.

## Download

Current version: **1.0.0**. Click the package for your viewer:

| Viewer | Download | macOS | Mac |
|---|---|---|---|
| IsiX DICOM Viewer 6.0.3+ (GitHub build) | [**FixDICOM-IsiX-1.0.0.zip**](https://github.com/ArtemSobolev95/FixDICOM-macOS/raw/main/downloads/FixDICOM-IsiX-1.0.0.zip) | 15 or later | Apple silicon and Intel |
| Horos 4.0.1 | [**FixDICOM-Horos-1.0.0.zip**](https://github.com/ArtemSobolev95/FixDICOM-macOS/raw/main/downloads/FixDICOM-Horos-1.0.0.zip) | 11 or later | Apple silicon and Intel |

Each package works on both kinds of Mac. The App Store version of IsiX loads no plugins; use the
[GitHub build of IsiX](https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases).

### Install

1. Quit the viewer.
2. Unzip the package and double-click **Install FixDICOM.command**.
   If macOS says the developer cannot be verified: System Settings › Privacy & Security ›
   *Open Anyway*, then double-click it again.
3. Open the viewer. *Plugins › Plugins Manager* should list FixDICOM as loaded.

## Use

1. *Plugins › Database › Fix and Import DICOM Study…* (or the toolbar button: right-click the
   toolbar › *Customize Toolbar…* and drag **Fix and Import DICOM Study…** onto it).
2. Finder opens: choose the study folder (several: hold ⌘).
3. The files are repaired and imported. A summary shows how many were fixed; *Show Log* lists them
   (`~/Library/Application Support/FixDICOM/log.txt`).

The original folder is never modified. Repaired copies are written to the database's INCOMING
folder, which the viewer imports into its database as it does files received from the network.

## What it does

The same as this shell function, without needing DCMTK:

```sh
# for every file except DICOMDIR and hidden files:
cp "$f" "$out"
dcmdump "$f" 2>&1 >/dev/null | grep -q "Sequence Delimitation Item missing" \
  && printf '\xfe\xff\xdd\xe0\x00\x00\x00\x00' >> "$out"
```

`Sources/FDRepair.c` walks each file element by element (explicit and implicit VR, little and big
endian, undefined-length UN, encapsulated pixel data). When a file ends exactly on an element
boundary with undefined-length sequences or items still open, it appends the delimiters that close
them, innermost first: FFFE,E00D for an open item, FFFE,E0DD for an open sequence. In the usual
Siemens case that is exactly the 8 bytes above.

| File | What happens |
|---|---|
| Complete DICOM | copied unchanged and imported |
| Sequence/item delimiter missing at the end | delimiter(s) appended, imported |
| Ends inside an element (cut short), deflated syntax | imported unchanged, listed in the log |
| Not DICOM | skipped |

## Build

Needs the Xcode command line tools. The plugin SDK headers are in [`third_party/`](third_party).

```sh
./build.sh install                   # IsiX build, installs into IsiX
TARGET=horos ./build.sh install      # Horos build, installs into Horos
TARGET=isix ./package.sh; TARGET=horos ./package.sh   # zips in dist/
```

Or double-click **Build IsiX version.command** / **Build Horos version.command**.

Test of the repair code (plain C and Python, runs anywhere):

```sh
cd tests && python3 make_samples.py samples && cc -o tr test_repair.c ../Sources/FDRepair.c && ./tr samples/*
```

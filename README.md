# FixDICOM for IsiX and Horos (macOS)

Repairs DICOM files whose last **Sequence Delimitation Item** is missing (a Siemens export quirk:
DCMTK reports *"Sequence Delimitation Item missing"*) and imports the study into the database of
**IsiX DICOM Viewer** or **Horos**, in one step.

## Install

Ready-made packages are not uploaded yet. Build from source (below): download this repository
(*Code › Download ZIP*), unzip it, quit the viewer and double-click **Build IsiX version.command**
(or **Build Horos version.command**). The App Store version of IsiX loads no plugins; use the
[GitHub build of IsiX](https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases).

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

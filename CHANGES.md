# Changes

## 1.0.0 — first release

- Plugins › Database › Fix and Import DICOM Study…: choose study folder(s) in Finder; every file is
  checked, missing Sequence/Item Delimitation Items at the end of the file are added, and the files
  are imported through the database's INCOMING folder. The original folder is not modified.
- No DCMTK needed: built-in check of the DICOM structure (explicit/implicit VR, LE/BE, UN, pixel data)
- Progress window with Stop; summary; log in ~/Library/Application Support/FixDICOM/log.txt

FixDICOM @VERSION@ — repair and import DICOM studies with a missing Sequence Delimitation Item
================================================================================================

Some exports (notably Siemens) end their files without the last Sequence Delimitation Item.
DCMTK reports "Sequence Delimitation Item missing" and the viewer refuses or misreads the files.
FixDICOM adds the missing delimiter (8 bytes at the end of the file) and imports the study.

INSTALL
  Quit the viewer, double-click "Install FixDICOM.command", open the viewer.
  If macOS says the developer cannot be verified: System Settings > Privacy & Security > Open Anyway.

USE
  1. Plugins > Database > "Fix and Import DICOM Study…" (or the toolbar button, if you added it).
  2. Choose the study folder (the CD/USB folder, or a folder with the files; several: hold Cmd).
  3. Every file in it (subfolders included; DICOMDIR and hidden files aside) is checked. Files with
     the missing delimiter get it added; complete files are copied as they are. The copies go into
     the viewer's database. The original folder is never changed.
  4. A summary says how many files were repaired. Show Log lists them:
     ~/Library/Application Support/FixDICOM/log.txt

  Files that end in the middle of an element (cut short) cannot be repaired this way; they are
  imported as they are and listed in the log. Files that are not DICOM are skipped.

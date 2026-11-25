//
//  FDRepair.h — finds DICOM files whose undefined-length sequences (or items) are never closed
//  before the end of the file, and works out the delimiters that close them.
//
//  Siemens exports sometimes end with the last Sequence Delimitation Item (FFFE,E0DD) missing;
//  DCMTK then reports "Sequence Delimitation Item missing" and some viewers refuse the file.
//  Appending the missing delimiters (8 bytes each) repairs it. Plain C, no dependencies.
//

#ifndef FDREPAIR_H
#define FDREPAIR_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    FD_OK = 0,          // complete DICOM file, nothing to do
    FD_NEEDS_FIX,       // DICOM file ending inside open sequences/items: append `tail`
    FD_NOT_DICOM,       // not recognised as DICOM
    FD_DAMAGED,         // ends inside an element, or not understood: copied unchanged
    FD_UNSUPPORTED      // deflated transfer syntax: left as is
} fd_status;

#define FD_MAX_TAIL 512

typedef struct {
    fd_status status;
    uint8_t tail[FD_MAX_TAIL];     // bytes to append (FD_NEEDS_FIX)
    size_t tailLength;
    int missingSequenceDelimiters; // FFFE,E0DD to add
    int missingItemDelimiters;     // FFFE,E00D to add
    char message[160];             // what was found, for the log
} fd_result;

// Looks at a whole file in memory. Never writes.
void fd_analyze(const uint8_t *data, size_t length, fd_result *result);

#endif

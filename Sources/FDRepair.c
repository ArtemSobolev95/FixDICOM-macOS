//
//  FDRepair.c — see FDRepair.h.
//
//  Walks the data set element by element, following only what can be left open at the end of a
//  file: sequences and items of undefined length (including undefined-length UN, read as implicit
//  VR little endian, and encapsulated pixel data). Elements of defined length are skipped whole,
//  so no data dictionary is needed. Reaching the end of the file exactly on an element boundary
//  with sequences or items still open is the Siemens quirk: the delimiters that close them,
//  innermost first, are what has to be appended.
//

#include "FDRepair.h"
#include <stdio.h>
#include <string.h>

#define UNDEFINED 0xFFFFFFFFu
#define MAX_DEPTH 64

enum { ROOT, ITEM, SEQUENCE };

typedef struct {
    int kind;
    int implicitVR;
    int bigEndian;
    int fragments;   // encapsulated pixel data: items are fragments of defined length
} frame;

static uint16_t rd16(const uint8_t *p, int big) { return big ? (uint16_t)(p[0] << 8 | p[1]) : (uint16_t)(p[1] << 8 | p[0]); }
static uint32_t rd32(const uint8_t *p, int big)
{
    return big ? ((uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3])
               : ((uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0]);
}

static int isVR(const uint8_t *p)
{
    static const char *vrs[] = { "AE","AS","AT","CS","DA","DS","DT","FD","FL","IS","LO","LT","OB","OD","OF",
        "OL","OV","OW","PN","SH","SL","SQ","SS","ST","SV","TM","UC","UI","UL","UN","UR","US","UT","UV", NULL };
    for (int i = 0; vrs[i]; i++) if (p[0] == vrs[i][0] && p[1] == vrs[i][1]) return 1;
    return 0;
}

static int isLongVR(const uint8_t *p)
{
    static const char *vrs[] = { "OB","OD","OF","OL","OV","OW","SQ","UC","UN","UR","UT","SV","UV", NULL };
    for (int i = 0; vrs[i]; i++) if (p[0] == vrs[i][0] && p[1] == vrs[i][1]) return 1;
    return 0;
}

static void put(fd_result *r, uint16_t element, int big)
{
    uint8_t b[8] = { 0 };
    if (big) { b[0] = 0xFF; b[1] = 0xFE; b[2] = (uint8_t)(element >> 8); b[3] = (uint8_t)element; }
    else     { b[0] = 0xFE; b[1] = 0xFF; b[2] = (uint8_t)element; b[3] = (uint8_t)(element >> 8); }
    if (r->tailLength + 8 <= FD_MAX_TAIL) { memcpy(r->tail + r->tailLength, b, 8); r->tailLength += 8; }
}

typedef enum { WALK_OK, WALK_SHORT, WALK_BAD } walk_status;

// Walks from `pos` to the end of the file. On WALK_OK the stack holds what is still open.
static walk_status walk(const uint8_t *d, size_t n, size_t pos, frame *stack, int *depthOut, size_t *where)
{
    int depth = 0;
#define NEED(k) do { if (pos + (k) > n || pos + (k) < pos) { *where = pos; *depthOut = depth; return WALK_SHORT; } } while (0)
#define BAD()   do { *where = pos; *depthOut = depth; return WALK_BAD; } while (0)
    while (pos < n) {
        frame *f = &stack[depth];
        int big = f->bigEndian;
        if (f->kind == SEQUENCE) {
            NEED(8);
            uint16_t g = rd16(d + pos, big), e = rd16(d + pos + 2, big);
            uint32_t len = rd32(d + pos + 4, big);
            if (g != 0xFFFE) BAD();
            if (e == 0xE000) {
                pos += 8;
                if (len == UNDEFINED) {
                    if (f->fragments || depth + 1 >= MAX_DEPTH) BAD();
                    stack[++depth] = (frame){ ITEM, f->implicitVR, f->bigEndian, 0 };
                } else {
                    NEED(len);
                    pos += len;
                }
            } else if (e == 0xE0DD) {
                pos += 8;
                depth--;
            } else BAD();
            continue;
        }

        // In the data set or in an item.
        NEED(4);
        uint16_t g = rd16(d + pos, big), e = rd16(d + pos + 2, big);
        if (g == 0xFFFE) {
            if (e == 0xE00D && f->kind == ITEM) { NEED(8); pos += 8; depth--; continue; }
            BAD();
        }
        uint32_t len;
        const uint8_t *vr = NULL;
        if (f->implicitVR) {
            NEED(8);
            len = rd32(d + pos + 4, big);
            pos += 8;
        } else {
            NEED(6);
            vr = d + pos + 4;
            if (!isVR(vr)) BAD();
            if (isLongVR(vr)) { NEED(12); len = rd32(d + pos + 8, big); pos += 12; }
            else { NEED(8); len = rd16(d + pos + 6, big); pos += 8; }
        }
        if (len == UNDEFINED) {
            if (depth + 1 >= MAX_DEPTH) BAD();
            frame next = { SEQUENCE, f->implicitVR, f->bigEndian, 0 };
            if (f->implicitVR) {
                next.fragments = (g == 0x7FE0 && e == 0x0010);
            } else if (vr[0] == 'S' && vr[1] == 'Q') {
            } else if (vr[0] == 'U' && vr[1] == 'N') {
                next.implicitVR = 1; next.bigEndian = 0;   // PS3.5 7.8: contents are implicit VR LE
            } else if (vr[0] == 'O' && (vr[1] == 'B' || vr[1] == 'W')) {
                next.fragments = 1;
            } else BAD();
            stack[++depth] = next;
        } else {
            NEED(len);
            pos += len;
        }
    }
    *where = pos;
    *depthOut = depth;
    return WALK_OK;
#undef NEED
#undef BAD
}

static void finish(fd_result *r, walk_status w, frame *stack, int depth, size_t where, int strict)
{
    if (w == WALK_OK) {
        if (depth == 0) { r->status = FD_OK; snprintf(r->message, sizeof r->message, "complete"); return; }
        for (int i = depth; i >= 1; i--) {
            if (stack[i].kind == ITEM) { put(r, 0xE00D, stack[i].bigEndian); r->missingItemDelimiters++; }
            else { put(r, 0xE0DD, stack[i].bigEndian); r->missingSequenceDelimiters++; }
        }
        r->status = FD_NEEDS_FIX;
        snprintf(r->message, sizeof r->message, "%d Sequence Delimitation Item(s) and %d Item Delimitation Item(s) missing",
                 r->missingSequenceDelimiters, r->missingItemDelimiters);
        return;
    }
    if (strict) { r->status = FD_NOT_DICOM; snprintf(r->message, sizeof r->message, "not a DICOM file"); return; }
    r->status = FD_DAMAGED;
    snprintf(r->message, sizeof r->message, w == WALK_SHORT ? "file ends inside an element at byte %zu"
                                                            : "structure not understood at byte %zu", where);
}

void fd_analyze(const uint8_t *d, size_t n, fd_result *r)
{
    memset(r, 0, sizeof *r);
    frame stack[MAX_DEPTH];
    int depth = 0;
    size_t where = 0;

    if (n >= 132 && memcmp(d + 128, "DICM", 4) == 0) {
        // File meta information: explicit VR little endian, group 0002.
        size_t pos = 132;
        char ts[65] = "";
        while (pos + 8 <= n && rd16(d + pos, 0) == 0x0002) {
            uint16_t e = rd16(d + pos + 2, 0);
            if (!isVR(d + pos + 4)) break;
            uint32_t len; size_t hdr;
            if (isLongVR(d + pos + 4)) {
                if (pos + 12 > n) break;
                len = rd32(d + pos + 8, 0); hdr = 12;
            } else { len = rd16(d + pos + 6, 0); hdr = 8; }
            if (len == UNDEFINED || pos + hdr + len > n) {
                r->status = FD_DAMAGED; snprintf(r->message, sizeof r->message, "file meta information damaged"); return;
            }
            if (e == 0x0010) {
                size_t k = len < 64 ? len : 64;
                memcpy(ts, d + pos + hdr, k); ts[k] = 0;
                while (k > 0 && (ts[k - 1] == 0 || ts[k - 1] == ' ')) ts[--k] = 0;
            }
            pos += hdr + len;
        }
        int implicitVR = strcmp(ts, "1.2.840.10008.1.2") == 0;
        int bigEndian = strcmp(ts, "1.2.840.10008.1.2.2") == 0;
        if (strcmp(ts, "1.2.840.10008.1.2.1.99") == 0) {
            r->status = FD_UNSUPPORTED; snprintf(r->message, sizeof r->message, "deflated transfer syntax, left as is"); return;
        }
        stack[0] = (frame){ ROOT, implicitVR, bigEndian, 0 };
        walk_status w = walk(d, n, pos, stack, &depth, &where);
        finish(r, w, stack, depth, where, 0);
        return;
    }

    // No preamble: accepted only when it starts like a data set and reads through to the end.
    if (n < 8) { r->status = FD_NOT_DICOM; snprintf(r->message, sizeof r->message, "not a DICOM file"); return; }
    uint16_t g = rd16(d, 0);
    if (g != 0x0002 && g != 0x0008) { r->status = FD_NOT_DICOM; snprintf(r->message, sizeof r->message, "not a DICOM file"); return; }
    stack[0] = (frame){ ROOT, !isVR(d + 4), 0, 0 };
    walk_status w = walk(d, n, 0, stack, &depth, &where);
    finish(r, w, stack, depth, where, 1);
}

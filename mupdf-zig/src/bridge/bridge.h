#ifndef MUPDF_ZIG_BRIDGE_H
#define MUPDF_ZIG_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Return codes for fallible bridge functions. Stable — Zig wrapper switches on these. */
#define MUPDF_BRIDGE_OK              0
#define MUPDF_BRIDGE_ERR_OPEN        1  /* file missing, not a PDF, or corrupt */
#define MUPDF_BRIDGE_ERR_ENCRYPTED   2  /* needs a password */
#define MUPDF_BRIDGE_ERR_BACKEND     3  /* generic mupdf throw / OOM */
#define MUPDF_BRIDGE_ERR_RANGE       4  /* slice range out of bounds */

/* MuPDF version string. Lifetime: static. Never NULL. */
const char *mupdf_zig_bridge_fz_version(void);

/* Forward decl so we can return a pointer without including <mupdf/fitz.h> in this header. */
typedef struct fz_context fz_context;

/*
 * Create an fz_context with handlers registered. Returns NULL on OOM or context init failure.
 * Caller must drop with mupdf_zig_bridge_drop_context.
 */
fz_context *mupdf_zig_bridge_new_context(void);

/* Drop an fz_context previously returned from new_context. NULL-safe. */
void mupdf_zig_bridge_drop_context(fz_context *ctx);

/*
 * Clone a context so it can be used from another thread. The clone shares the
 * underlying caches but has its own thread-local state. Caller must drop with
 * mupdf_zig_bridge_drop_context. Returns NULL on OOM or clone failure.
 */
fz_context *mupdf_zig_bridge_clone_context(fz_context *ctx);

typedef struct pdf_document pdf_document;

/*
 * Open a PDF document. Returns one of MUPDF_BRIDGE_* codes. On OK, *out_doc holds
 * a non-null pdf_document pointer that the caller must drop with drop_document.
 * On non-OK, *out_doc is left NULL. Encrypted PDFs return MUPDF_BRIDGE_ERR_ENCRYPTED
 * and the partially-opened document is dropped internally.
 */
int mupdf_zig_bridge_open_document(fz_context *ctx, const char *path, pdf_document **out_doc);

/* Drop a pdf_document previously returned from open_document. NULL-safe. */
void mupdf_zig_bridge_drop_document(fz_context *ctx, pdf_document *doc);

/*
 * Write the page count of `doc` to *out_count. Returns MUPDF_BRIDGE_OK on success,
 * MUPDF_BRIDGE_ERR_BACKEND if MuPDF throws.
 */
int mupdf_zig_bridge_count_pages(fz_context *ctx, pdf_document *doc, int *out_count);

/*
 * Write a copy of `doc` to `out_path` containing only pages [start_page, end_page]
 * (1-based, inclusive). Writes resulting file size to *out_bytes on success.
 *
 * Returns:
 *   MUPDF_BRIDGE_OK         — output written, *out_bytes valid
 *   MUPDF_BRIDGE_ERR_RANGE  — start < 1, end < start, or end > page_count
 *   MUPDF_BRIDGE_ERR_BACKEND — any MuPDF throw during slice/save, or stat() failure
 *
 * Note: doc is modified in place by pdf_rearrange_pages. After a successful slice,
 * the document is no longer usable for further operations — callers should drop it.
 *
 * On error returns, out_path may contain a partial or corrupted file (pdf_save_document
 * is not atomic). Callers SHOULD delete it before retrying.
 */
int mupdf_zig_bridge_slice(fz_context *ctx, pdf_document *doc,
                           const char *out_path,
                           int start_page, int end_page,
                           unsigned long long *out_bytes);

#ifdef __cplusplus
}
#endif

#endif

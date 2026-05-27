#include "bridge.h"
#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <sys/stat.h>
#include <pthread.h>

const char *mupdf_zig_bridge_fz_version(void)
{
    return FZ_VERSION;
}

/*
 * MuPDF requires lock callbacks to support multi-threaded use via
 * fz_clone_context. We provide a process-wide set of pthread mutexes that all
 * contexts (and their clones) share. This is the pattern MuPDF's own
 * multi-threaded.c example uses; the mutexes guard MuPDF's internal global-ish
 * caches (FZ_LOCK_ALLOC / FZ_LOCK_FREETYPE / FZ_LOCK_GLYPHCACHE), so a single
 * process-wide set is correct.
 */
static pthread_mutex_t bridge_mutexes[FZ_LOCK_MAX];
static pthread_once_t  bridge_mutex_once = PTHREAD_ONCE_INIT;
static int             bridge_mutex_init_ok = 0;

static void bridge_init_mutexes(void)
{
    for (int i = 0; i < FZ_LOCK_MAX; i++) {
        if (pthread_mutex_init(&bridge_mutexes[i], NULL) != 0) {
            return; /* leaves bridge_mutex_init_ok = 0 */
        }
    }
    bridge_mutex_init_ok = 1;
}

static void bridge_lock(void *user, int which)
{
    (void)user;
    pthread_mutex_lock(&bridge_mutexes[which]);
}

static void bridge_unlock(void *user, int which)
{
    (void)user;
    pthread_mutex_unlock(&bridge_mutexes[which]);
}

static const fz_locks_context bridge_locks_template = {
    .user = NULL,
    .lock = bridge_lock,
    .unlock = bridge_unlock,
};

fz_context *mupdf_zig_bridge_new_context(void)
{
    pthread_once(&bridge_mutex_once, bridge_init_mutexes);
    if (!bridge_mutex_init_ok) return NULL;

    fz_context *ctx = fz_new_context(NULL, &bridge_locks_template, FZ_STORE_UNLIMITED);
    if (!ctx) return NULL;

    fz_try(ctx) {
        fz_register_document_handlers(ctx);
    }
    fz_catch(ctx) {
        fz_drop_context(ctx);
        return NULL;
    }
    return ctx;
}

void mupdf_zig_bridge_drop_context(fz_context *ctx)
{
    if (ctx) fz_drop_context(ctx);
}

int mupdf_zig_bridge_open_document(fz_context *ctx, const char *path, pdf_document **out_doc)
{
    pdf_document *doc = NULL;
    *out_doc = NULL;

    fz_try(ctx) {
        doc = pdf_open_document(ctx, path);
    }
    fz_catch(ctx) {
        return MUPDF_BRIDGE_ERR_OPEN;
    }

    int rc = MUPDF_BRIDGE_OK;
    fz_try(ctx) {
        /* User and owner password requirements both map to ENCRYPTED — by design.
         * Chargesheet rejects all password-protected files at upload time. */
        if (pdf_needs_password(ctx, doc)) {
            rc = MUPDF_BRIDGE_ERR_ENCRYPTED;
        }
    }
    fz_catch(ctx) {
        rc = MUPDF_BRIDGE_ERR_BACKEND;
    }

    if (rc != MUPDF_BRIDGE_OK) {
        pdf_drop_document(ctx, doc);
        return rc;
    }

    *out_doc = doc;
    return MUPDF_BRIDGE_OK;
}

void mupdf_zig_bridge_drop_document(fz_context *ctx, pdf_document *doc)
{
    if (doc) pdf_drop_document(ctx, doc);
}

int mupdf_zig_bridge_count_pages(fz_context *ctx, pdf_document *doc, int *out_count)
{
    int count = 0;
    fz_try(ctx) {
        count = pdf_count_pages(ctx, doc);
    }
    fz_catch(ctx) {
        return MUPDF_BRIDGE_ERR_BACKEND;
    }
    if (count < 0) return MUPDF_BRIDGE_ERR_BACKEND;
    *out_count = count;
    return MUPDF_BRIDGE_OK;
}

int mupdf_zig_bridge_slice(fz_context *ctx, pdf_document *doc,
                           const char *out_path,
                           int start_page, int end_page,
                           unsigned long long *out_bytes)
{
    int total = 0;
    fz_try(ctx) {
        total = pdf_count_pages(ctx, doc);
    }
    fz_catch(ctx) {
        return MUPDF_BRIDGE_ERR_BACKEND;
    }

    if (start_page < 1 || end_page < start_page || end_page > total) {
        return MUPDF_BRIDGE_ERR_RANGE;
    }

    int n = end_page - start_page + 1;
    int *retain = NULL;
    int rc = MUPDF_BRIDGE_OK;

    fz_try(ctx) {
        retain = fz_malloc(ctx, (size_t)n * sizeof(int));
        for (int i = 0; i < n; i++) {
            retain[i] = (start_page - 1) + i;  /* mupdf is 0-indexed */
        }
        pdf_rearrange_pages(ctx, doc, n, retain, PDF_CLEAN_STRUCTURE_KEEP);
        /* do_garbage=2 drops objects orphaned by pdf_rearrange_pages (content
         * streams, images, fonts of pages no longer in the page tree) AND
         * compacts the xref. Without this the output PDF retains every byte of
         * the source — a 1-page slice of a 170-page document still weighs the
         * full source size. do_clean=1 also prunes orphan refs inside content
         * streams. See mutool clean -gg for the equivalent CLI behavior. */
        pdf_write_options opts = pdf_default_write_options;
        opts.do_garbage = 2;
        opts.do_clean = 1;
        pdf_save_document(ctx, doc, out_path, &opts);
    }
    fz_catch(ctx) {
        rc = MUPDF_BRIDGE_ERR_BACKEND;
    }

    if (retain) fz_free(ctx, retain);

    if (rc == MUPDF_BRIDGE_OK) {
        struct stat st;
        if (stat(out_path, &st) == 0) {
            *out_bytes = (unsigned long long)st.st_size;
        } else {
            rc = MUPDF_BRIDGE_ERR_BACKEND;
        }
    }
    return rc;
}

fz_context *mupdf_zig_bridge_clone_context(fz_context *ctx)
{
    if (!ctx) return NULL;
    return fz_clone_context(ctx);
}

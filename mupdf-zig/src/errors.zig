/// Error set returned by mupdf-zig public APIs.
/// - `OutOfMemory`: allocator failure (Zig or fz_new_context returning NULL).
/// - `InvalidPdf`: pdf_open_document threw (file missing, not a PDF, corrupt).
/// - `EncryptedPdf`: pdf_needs_password returned non-zero on the opened document.
/// - `InvalidPageRange`: slice range invalid (start/end out of bounds or end < start).
/// - `PdfBackendError`: any other fz_try/fz_catch throw from MuPDF.
pub const Error = error{
    OutOfMemory,
    InvalidPdf,
    EncryptedPdf,
    InvalidPageRange,
    PdfBackendError,
};

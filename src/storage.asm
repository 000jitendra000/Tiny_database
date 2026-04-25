; ============================================================
; storage.asm — data.db operations (append and read values)
; ============================================================
; data.db format (recap):
;
;   Byte 0:  [uint32_t len] [len bytes of value data]
;   Next:    [uint32_t len] [len bytes of value data]
;   ...
;
; storage_append returns the byte offset of the uint32_t length
; prefix it just wrote. That offset is what gets stored in index.db.
;
; storage_read takes that same offset, reads the 4-byte length,
; then reads exactly that many bytes into the caller's buffer.

%include "include/constants.inc"
%include "include/file.inc"

section .data

; Path to data file — relative to CWD where tinydb is run
data_path:  db "db/data.db", 0


section .bss

; Temporary buffer to hold the 4-byte length prefix
; when writing or reading records in data.db
len_buf:    resb 4


section .text

global storage_append
global storage_read


; ────────────────────────────────────────────────────────────
; storage_append — write a new value record to data.db
;
; Layout written to data.db:
;   [4 bytes: uint32_t value_length][N bytes: value data]
;
; Args:
;   rdi = pointer to value bytes
;   rsi = value length (N)
;
; Returns:
;   rax = byte offset of the written record (where the 4-byte
;         length prefix starts) — store this in index.db
;   rax = -1 on any error
;
; Register usage (callee-saved — preserved across calls):
;   r12 = value pointer (rdi saved here)
;   r13 = value length  (rsi saved here)
;   r14 = file descriptor for data.db
;   r15 = the byte offset we'll return
; ────────────────────────────────────────────────────────────
storage_append:
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi            ; save value pointer
    mov     r13, rsi            ; save value length

    ; ── Step 1: Open data.db for read/write, create if missing ─
    ; Flags: O_RDWR | O_CREAT | O_APPEND
    ; O_APPEND means the kernel atomically seeks to EOF before
    ; each write — critical for correctness on appends.
    ; Mode 0o644: owner rw, group r, world r

    mov     rdi, data_path
    mov     rsi, O_RDWR | O_CREAT | O_APPEND
    mov     rdx, MODE_FILE
    call    file_open
    cmp     rax, 0
    jl      .err                ; negative fd = error
    mov     r14, rax            ; r14 = fd

    ; ── Step 2: Find current EOF = our write offset ───────────
    ; lseek(fd, 0, SEEK_END) returns the current file size,
    ; which equals the byte offset where our next write will land.
    ; Even though O_APPEND handles the actual seek internally,
    ; we need to KNOW the offset so we can store it in index.db.

    mov     rdi, r14            ; fd
    mov     rsi, 0              ; offset = 0
    mov     rdx, SEEK_END       ; from end of file
    call    file_seek
    cmp     rax, 0
    jl      .err_close
    mov     r15, rax            ; r15 = current EOF offset (our record's start)

    ; ── Step 3: Write the 4-byte length prefix ────────────────
    ; We store val_len as a little-endian uint32_t.
    ; x86 is natively little-endian, so a simple mov stores
    ; the bytes in exactly the right byte order.

    mov     dword [len_buf], r13d   ; r13d = lower 32 bits of r13 = val_len
                                    ; stored at len_buf as 4 bytes LE

    mov     rdi, r14            ; fd
    mov     rsi, len_buf        ; pointer to the 4 bytes
    mov     rdx, 4              ; write exactly 4 bytes
    call    file_write
    cmp     rax, 4
    jne     .err_close          ; short write = error

    ; ── Step 4: Write the actual value bytes ──────────────────
    mov     rdi, r14
    mov     rsi, r12            ; value pointer
    mov     rdx, r13            ; value length
    call    file_write
    cmp     rax, r13            ; did we write all bytes?
    jne     .err_close

    ; ── Step 5: Close the file ────────────────────────────────
    mov     rdi, r14
    call    file_close

    ; Return the offset where this record begins
    mov     rax, r15
    jmp     .done

.err_close:
    mov     rdi, r14
    call    file_close
.err:
    mov     rax, -1
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret


; ────────────────────────────────────────────────────────────
; storage_read — read a value from data.db at a given offset
;
; The caller knows the offset (from index.db) and optionally
; the value length. We pass both to avoid an extra seek.
;
; Args:
;   rdi = byte offset into data.db (points to 4-byte len prefix)
;   rsi = value length in bytes (from index record's val_len)
;   rdx = output buffer pointer
;
; Returns:
;   rax = number of bytes read into buffer (= val_len on success)
;   rax = -1 on error
;
; Register usage:
;   r12 = output buffer
;   r13 = val_len (rsi saved)
;   r14 = file descriptor
; ────────────────────────────────────────────────────────────
storage_read:
    push    rbx
    push    r12
    push    r13
    push    r14

    ; Save ALL args before any call can clobber them.
    ; rdi=offset → rbx (callee-saved, safe across calls)
    ; rsi=val_len → r13
    ; rdx=output_buf → r12
    mov     rbx, rdi            ; rbx = data.db byte offset
    mov     r13, rsi            ; r13 = val_len
    mov     r12, rdx            ; r12 = output buffer

    ; ── Step 1: Open data.db read-only ────────────────────────
    mov     rdi, data_path
    mov     rsi, O_RDONLY
    mov     rdx, 0              ; mode unused for O_RDONLY
    call    file_open
    cmp     rax, 0
    jl      .err
    mov     r14, rax


    ; ── Step 3: Seek to the record's byte offset ──────────────
    ; rbx safely holds the original offset argument.
    mov     rdi, r14
    mov     rsi, rbx
    mov     rdx, SEEK_SET
    call    file_seek
    cmp     rax, 0
    jl      .err_close

    ; ── Step 3: Skip the 4-byte length prefix ─────────────────
    ; We already know val_len from the index record (passed as rsi).
    ; We still need to advance past the 4-byte prefix. We do this
    ; by seeking forward 4 more bytes.
    ;
    ; Alternative: read the 4 bytes into len_buf and discard them.
    ; Reading is cleaner than a second seek:

    mov     rdi, r14
    mov     rsi, len_buf        ; discard buffer
    mov     rdx, 4
    call    file_read
    cmp     rax, 4
    jne     .err_close

    ; ── Step 4: Read val_len bytes into caller's buffer ───────
    mov     rdi, r14
    mov     rsi, r12            ; output buffer
    mov     rdx, r13            ; val_len
    call    file_read
    cmp     rax, r13
    jne     .err_close
    mov     r13, rax            ; save bytes read

    mov     rdi, r14
    call    file_close

    mov     rax, r13            ; return bytes read
    jmp     .done

.err_close:
    mov     rdi, r14
    call    file_close
.err:
    mov     rax, -1
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
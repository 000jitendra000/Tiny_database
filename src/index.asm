; ============================================================
; index.asm — index.db operations: put, find, delete
; ============================================================
; index.db stores fixed-size 80-byte records:
;
; Offset  Size  Field
;      0     1  key_len   — valid bytes in key[] (uint8_t)
;      1    63  key[]     — zero-padded key string
;     64     8  offset    — byte offset in data.db (uint64_t LE)
;     72     4  val_len   — value size in bytes (uint32_t LE)
;     76     1  deleted   — 0=live, 1=tombstoned
;     77     3  padding
;
; Because records are fixed-size, we can:
;   - Append a new record with lseek(SEEK_END) + write(80 bytes)
;   - Update deleted flag in-place with lseek(record_offset+76) + write(1 byte)
;   - Scan all records with a simple read loop

%include "include/constants.inc"
%include "include/file.inc"
%include "include/utils.inc"

section .data

index_path: db "db/index.db", 0

section .bss

; Scratch buffer for reading one record at a time during scan
scan_buf:   resb INDEX_RECORD_SIZE

section .text

global index_put
global index_find
global index_delete


; ────────────────────────────────────────────────────────────
; index_put — append a new record to index.db
;
; Builds an 80-byte record in memory, then writes it atomically.
;
; Args:
;   rdi = key pointer
;   rsi = key_len
;   rdx = data_offset (uint64_t — offset in data.db)
;   rcx = val_len (uint32_t)
;
; Returns:
;   rax = 0 on success, -1 on error
;
; Register usage:
;   r12 = key pointer
;   r13 = key_len
;   r14 = data_offset
;   r15 = val_len
;   rbx = fd
; ────────────────────────────────────────────────────────────
index_put:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     r15, rcx

    ; ── Step 1: Build the 80-byte record in scan_buf ──────────
    ; We reuse scan_buf as a write buffer here.
    ; First, zero it entirely so padding bytes are clean.

    ; Zero out all 80 bytes
    ; We do this with 10 × 8-byte stores (10 * 8 = 80)
    mov     qword [scan_buf + 0],  0
    mov     qword [scan_buf + 8],  0
    mov     qword [scan_buf + 16], 0
    mov     qword [scan_buf + 24], 0
    mov     qword [scan_buf + 32], 0
    mov     qword [scan_buf + 40], 0
    mov     qword [scan_buf + 48], 0
    mov     qword [scan_buf + 56], 0
    mov     qword [scan_buf + 64], 0
    mov     qword [scan_buf + 72], 0

    ; Write key_len at offset 0
    mov     byte [scan_buf + INDEX_OFF_KEYLEN], r13b   ; r13b = low byte of r13

    ; Copy key bytes into key[] field at offset 1
    ; We use a simple byte-copy loop.
    ; rdi = destination, rsi = source, rcx = count
    ; (We temporarily use rcx as the loop counter — it's caller-saved so ok)
    mov     rdi, scan_buf + INDEX_OFF_KEY   ; destination: &record.key
    mov     rsi, r12                         ; source: key pointer
    mov     rcx, r13                         ; count: key_len

.copy_key:
    cmp     rcx, 0
    jz      .copy_done
    mov     al, byte [rsi]      ; al = *src
    mov     byte [rdi], al      ; *dst = al
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .copy_key
.copy_done:

    ; Write data offset at field offset 64 (8 bytes, little-endian)
    ; x86 naturally stores in little-endian, so mov is correct
    mov     qword [scan_buf + INDEX_OFF_OFFSET], r14

    ; Write val_len at field offset 72 (4 bytes)
    mov     dword [scan_buf + INDEX_OFF_VALLEN], r15d

    ; deleted flag at offset 76 = 0 (already zeroed)

    ; ── Step 2: Open index.db for append ──────────────────────
    mov     rdi, index_path
    mov     rsi, O_RDWR | O_CREAT | O_APPEND
    mov     rdx, MODE_FILE
    call    file_open
    cmp     rax, 0
    jl      .err
    mov     rbx, rax            ; rbx = fd

    ; ── Step 3: Write the 80-byte record ──────────────────────
    mov     rdi, rbx
    mov     rsi, scan_buf
    mov     rdx, INDEX_RECORD_SIZE
    call    file_write
    cmp     rax, INDEX_RECORD_SIZE
    jne     .err_close

    mov     rdi, rbx
    call    file_close

    xor     rax, rax            ; return 0 = success
    jmp     .done

.err_close:
    mov     rdi, rbx
    call    file_close
.err:
    mov     rax, -1
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ────────────────────────────────────────────────────────────
; index_find — scan index.db for the last live record matching key
;
; We scan ALL records from the beginning. The LAST matching
; non-deleted record wins (handles duplicate SETs correctly).
;
; Args:
;   rdi = key pointer
;   rsi = key_len
;   rdx = result buffer (80 bytes) — filled on success
;
; Returns:
;   rax = 0  if found (result_buf filled with the record)
;   rax = -1 if not found
;
; Register usage:
;   r12 = key pointer
;   r13 = key_len
;   r14 = result buffer
;   r15 = fd
;   rbx = found flag (0=not found, 1=found)
; ────────────────────────────────────────────────────────────
index_find:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx

    ; ── Step 1: Open index.db read-only ───────────────────────
    mov     rdi, index_path
    mov     rsi, O_RDONLY
    mov     rdx, 0
    call    file_open
    cmp     rax, 0
    jl      .not_found          ; file doesn't exist → key not found
    mov     r15, rax

    xor     rbx, rbx            ; rbx = 0 = "not found yet"

    ; ── Step 2: Seek to beginning ─────────────────────────────
    mov     rdi, r15
    mov     rsi, 0
    mov     rdx, SEEK_SET
    call    file_seek

    ; ── Step 3: Read records one at a time ────────────────────
.scan_loop:
    mov     rdi, r15
    mov     rsi, scan_buf
    mov     rdx, INDEX_RECORD_SIZE
    call    file_read

    cmp     rax, 0              ; EOF — no more records
    jle     .scan_done

    cmp     rax, INDEX_RECORD_SIZE
    jne     .scan_done          ; short read = corrupted file, stop

    ; ── Step 4: Check deleted flag first ──────────────────────
    ; If deleted=1, skip this record — don't even compare key
    movzx   rax, byte [scan_buf + INDEX_OFF_DELETED]
    cmp     rax, 1
    je      .scan_loop          ; deleted → skip

    ; ── Step 5: Compare key lengths ───────────────────────────
    ; Quick reject: if key_len doesn't match, skip strcmp entirely
    movzx   rax, byte [scan_buf + INDEX_OFF_KEYLEN]
    cmp     rax, r13            ; record.key_len == our key_len?
    jne     .scan_loop

    ; ── Step 6: Compare key bytes ─────────────────────────────
    ; str_cmp(record.key, our_key)
    mov     rdi, scan_buf + INDEX_OFF_KEY
    mov     rsi, r12
    call    str_cmp
    test    rax, rax
    jnz     .scan_loop          ; not equal → keep scanning

    ; ── Step 7: Match found — copy record to result buf ───────
    ; Copy all 80 bytes using 10 × 8-byte loads/stores
    mov     rax, qword [scan_buf + 0]
    mov     qword [r14 + 0], rax
    mov     rax, qword [scan_buf + 8]
    mov     qword [r14 + 8], rax
    mov     rax, qword [scan_buf + 16]
    mov     qword [r14 + 16], rax
    mov     rax, qword [scan_buf + 24]
    mov     qword [r14 + 24], rax
    mov     rax, qword [scan_buf + 32]
    mov     qword [r14 + 32], rax
    mov     rax, qword [scan_buf + 40]
    mov     qword [r14 + 40], rax
    mov     rax, qword [scan_buf + 48]
    mov     qword [r14 + 48], rax
    mov     rax, qword [scan_buf + 56]
    mov     qword [r14 + 56], rax
    mov     rax, qword [scan_buf + 64]
    mov     qword [r14 + 64], rax
    mov     rax, qword [scan_buf + 72]
    mov     qword [r14 + 72], rax

    mov     rbx, 1              ; mark as found
    jmp     .scan_loop          ; keep scanning — last match wins!

.scan_done:
    mov     rdi, r15
    call    file_close

    cmp     rbx, 1
    jne     .not_found
    xor     rax, rax            ; return 0 = found
    jmp     .done

.not_found:
    mov     rax, -1
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ────────────────────────────────────────────────────────────
; index_delete — find a key in index.db and tombstone it
;
; We scan for the last live matching record, then seek back
; to its deleted field and write 0x01 in-place.
;
; Key insight: to write ONE byte at an arbitrary position, we:
;   1. Remember the byte offset of the deleted field
;   2. After the scan, seek back to that offset
;   3. Write a single 0x01 byte
;
; Args:
;   rdi = key pointer
;   rsi = key_len
;
; Returns:
;   rax = 0  if deleted successfully
;   rax = -1 if key not found
;
; Register usage:
;   r12 = key pointer
;   r13 = key_len
;   r14 = fd
;   r15 = file position of last matching record's start
;   rbx = found flag
; ────────────────────────────────────────────────────────────
index_delete:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi
    mov     r13, rsi

    ; Open for read+write (we need to write the deleted flag)
    mov     rdi, index_path
    mov     rsi, O_RDWR
    mov     rdx, 0
    call    file_open
    cmp     rax, 0
    jl      .not_found
    mov     r14, rax

    ; rbx = found-any flag: 0 = no match yet, 1 = at least one tombstoned.
    xor     rbx, rbx

    ; r15 = manual file position counter (start of current record).
    xor     r15, r15

    ; Seek to beginning of index.db
    mov     rdi, r14
    mov     rsi, 0
    mov     rdx, SEEK_SET
    call    file_seek

.scan_loop:
    ; r15 = start offset of the record we are about to read
    mov     rdi, r14
    mov     rsi, scan_buf
    mov     rdx, INDEX_RECORD_SIZE
    call    file_read

    cmp     rax, INDEX_RECORD_SIZE
    jne     .scan_done

    ; Skip already-deleted records
    movzx   rax, byte [scan_buf + INDEX_OFF_DELETED]
    cmp     rax, 1
    je      .next_record

    ; Compare key_len
    movzx   rax, byte [scan_buf + INDEX_OFF_KEYLEN]
    cmp     rax, r13
    jne     .next_record

    ; Compare key bytes
    mov     rdi, scan_buf + INDEX_OFF_KEY
    mov     rsi, r12
    call    str_cmp
    test    rax, rax
    jnz     .next_record

    ; ── Match: tombstone this record in-place ─────────────────
    ; Seek to its deleted field, write 0x01, seek back to continue.
    mov     rsi, r15
    add     rsi, INDEX_OFF_DELETED
    mov     rdi, r14
    mov     rdx, SEEK_SET
    call    file_seek
    cmp     rax, 0
    jl      .next_record        ; seek failed — skip, keep scanning

    mov     byte [scan_buf], 1
    mov     rdi, r14
    mov     rsi, scan_buf
    mov     rdx, 1
    call    file_write

    ; Seek back to after this record so the next read() is correct
    mov     rsi, r15
    add     rsi, INDEX_RECORD_SIZE
    mov     rdi, r14
    mov     rdx, SEEK_SET
    call    file_seek

    mov     rbx, 1              ; at least one record deleted

.next_record:
    add     r15, INDEX_RECORD_SIZE
    jmp     .scan_loop

.scan_done:
    cmp     rbx, 1
    jne     .not_found_close

    mov     rdi, r14
    call    file_close
    xor     rax, rax            ; return 0 = success
    jmp     .done

.not_found_close:
    mov     rdi, r14
    call    file_close
.not_found:
    mov     rax, -1
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
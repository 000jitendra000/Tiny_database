; ============================================================
; schema.asm — schema layer over the existing key-value engine
; ============================================================
; Responsibilities:
;   schema_init        — write db/schema.db
;   schema_load        — read db/schema.db, parse field names
;   schema_serialize   — join field value pointers with '|'
;   schema_print_record — print "field: value\n" for each field
;   schema_format_json  — build {"f1":"v1",...} JSON string
;
; Does NOT touch storage.asm or index.asm.
; The caller (main.asm / server.asm / http_server.asm) calls
; schema_serialize to build the value string, then passes it
; directly to storage_append / index_put as before.

%include "include/constants.inc"
%include "include/file.inc"

%define MAX_SCHEMA_FIELDS    16
%define MAX_FIELD_NAME_LEN   32
%define MAX_RECORD_VAL_LEN   1024
%define SCHEMA_FILE_BUF      512
%define FIELD_DELIM          '|'

section .data

schema_path:    db "db/schema.db", 0
newline:        db 0x0A
colon_space:    db ": "
colon_sp_len    equ $ - colon_space

section .bss

schema_read_buf: resb SCHEMA_FILE_BUF   ; raw schema.db contents

section .text

global schema_init
global schema_load
global schema_serialize
global schema_print_record
global schema_format_json

extern file_open
extern file_close
extern file_read
extern file_write
extern file_seek


; ── internal: write_bytes(fd, ptr, len) ──────────────────────
; rdi=fd, rsi=ptr, rdx=len  — thin wrapper, preserves rbx/r12/r13
write_bytes:
    call    file_write
    ret


; ── internal: itoa_byte(val, buf) → len ──────────────────────
; Converts rdi (small uint, 0-9999) to decimal in rsi.
; Returns rax = number of bytes written.
; Clobbers rcx, rdx. Uses no stack frame.
itoa_byte:
    push    rbx
    push    r12

    mov     rbx, rsi                ; buffer base
    lea     r12, [rbx + 20]         ; one-past-end
    mov     byte [r12], 0           ; null terminator

    mov     rax, rdi                ; number to convert

    ; special case: 0
    test    rax, rax
    jne     .convert

    dec     r12
    mov     byte [r12], '0'
    mov     rax, r12                ; start pointer
    mov     rcx, 1                  ; length
    jmp     .done

.convert:
.loop:
    xor     rdx, rdx
    mov     r8, 10
    div     r8                      ; quotient -> rax, remainder -> rdx

    dec     r12
    add     dl, '0'
    mov     byte [r12], dl

    test    rax, rax
    jne     .loop

    mov     rax, r12                ; start pointer
    lea     rcx, [rbx + 20]         ; rcx = end pointer (points at null)
    sub     rcx, r12                ; length INCLUDING digits, EXCLUDING null

.done:
    pop     r12
    pop     rbx
    ret

; ============================================================
; schema_init(field_count, names_buf, names_len)
;
; Writes schema.db as:  "<count> <names_string>\n"
; Example:              "3 name age city\n"
;
; rdi = field_count (integer)
; rsi = pointer to space-separated field names (e.g. "name age city")
; rdx = byte length of names string
; Returns: rax = 0 success, -1 error
; ============================================================
schema_init:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi            ; field_count
    mov     r13, rsi            ; names_buf
    mov     r14, rdx            ; names_len

    ; open schema.db (create/truncate)
    mov     rdi, schema_path
    mov     rsi, O_WRONLY | O_CREAT | O_TRUNC
    mov     rdx, MODE_FILE
    call    file_open
    cmp     rax, 0
    jl      .err_open

    push    rax                 ; save fd on stack

    ; write field count as decimal
    mov     rdi, r12
    lea     rsi, [schema_read_buf]
    call    itoa_byte           ; rax = ptr, rcx = len

    mov     rdi, [rsp]
    mov     rsi, rax
    mov     rdx, rcx
    call    file_write
    cmp     rax, 0
    jl      .err_write1

    ; write space
    mov     byte [schema_read_buf + 64], ' '
    mov     rdi, [rsp]
    lea     rsi, [schema_read_buf + 64]
    mov     rdx, 1
    call    file_write
    cmp     rax, 0
    jl      .err_write2

    ; write names string
    mov     rdi, [rsp]
    mov     rsi, r13
    mov     rdx, r14
    call    file_write
    cmp     rax, 0
    jl      .err_write3

    ; write newline
    mov     rdi, [rsp]
    lea     rsi, [newline]
    mov     rdx, 1
    call    file_write
    cmp     rax, 0
    jl      .err_write4

    ; close file
    mov     rdi, [rsp]
    call    file_close
    add     rsp, 8

    xor     rax, rax            ; success
    jmp     .ret

.err_open:
    mov     rax, -1
    jmp     .ret

.err_write1:
.err_write2:
.err_write3:
.err_write4:
    mov     rdi, [rsp]
    call    file_close
    add     rsp, 8
    mov     rax, -1
    jmp     .ret

.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; schema_load(out_field_count_ptr, out_names_array)
;
; Reads schema.db. Parses "<count> <name1> <name2>...\n"
; Fills:
;   *out_field_count_ptr = count
;   out_names_array[i]   = null-terminated field name (MAX_FIELD_NAME_LEN bytes each)
;
; rdi = pointer to uint64 to receive field count
; rsi = pointer to flat byte array [MAX_SCHEMA_FIELDS * MAX_FIELD_NAME_LEN]
; Returns: rax = field_count on success, -1 on error
; ============================================================
schema_load:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi            ; r12 = out_field_count_ptr
    mov     r13, rsi            ; r13 = out_names_array

    ; open schema.db read-only
    mov     rdi, schema_path
    mov     rsi, O_RDONLY
    mov     rdx, 0
    call    file_open
    cmp     rax, 0
    jl      .err
    mov     r14, rax            ; r14 = fd

    ; read into schema_read_buf
    mov     rdi, r14
    lea     rsi, [schema_read_buf]
    mov     rdx, SCHEMA_FILE_BUF - 1
    call    file_read
    cmp     rax, 1
    jl      .err_close
    mov     byte [schema_read_buf + rax], 0

    mov     rdi, r14
    call    file_close

    ; parse: read decimal number at start
    lea     rbx, [schema_read_buf]  ; rbx = scan pointer
    xor     r15, r15                 ; r15 = parsed field count

.parse_count:
    movzx   rax, byte [rbx]
    cmp     rax, '0'
    jl      .done_count
    cmp     rax, '9'
    jg      .done_count
    imul    r15, r15, 10
    sub     rax, '0'
    add     r15, rax
    inc     rbx
    jmp     .parse_count
.done_count:

    ; skip whitespace after count
    movzx   rax, byte [rbx]
    cmp     rax, ' '
    je      .skip_sp
    cmp     rax, 0x09           ; tab
    je      .skip_sp
    jmp     .parse_names
.skip_sp:
    inc     rbx
    jmp     .done_count         ; re-enter whitespace loop

.parse_names:
    ; parse space-separated field names into out_names_array
    ; r15 = total field count (already parsed)
    ; r14 = field index counter (reuse r14 now fd is closed)
    xor     r14, r14            ; r14 = current field index

.next_name:
    cmp     r14, r15
    jge     .load_done          ; parsed all fields

    movzx   rax, byte [rbx]
    cmp     rax, 0
    je      .load_done
    cmp     rax, 0x0A
    je      .load_done

    ; copy name bytes into names_array[r14]
    ; slot address = r13 + r14 * MAX_FIELD_NAME_LEN
    mov     rdi, r14
    imul    rdi, rdi, MAX_FIELD_NAME_LEN
    add     rdi, r13            ; rdi = slot base
    xor     rcx, rcx            ; rcx = byte counter within name

.copy_name:
    movzx   rax, byte [rbx]
    cmp     rax, 0
    je      .name_done
    cmp     rax, ' '
    je      .name_done
    cmp     rax, 0x0A
    je      .name_done
    cmp     rax, 0x09
    je      .name_done
    cmp     rcx, MAX_FIELD_NAME_LEN - 1
    jge     .name_done
    mov     byte [rdi + rcx], al
    inc     rcx
    inc     rbx
    jmp     .copy_name

.name_done:
    mov     byte [rdi + rcx], 0 ; null-terminate this field name
    inc     r14
    ; skip separator
    movzx   rax, byte [rbx]
    cmp     rax, ' '
    jne     .next_name
    inc     rbx
    jmp     .next_name

.load_done:
    ; store field count in caller's variable
    mov     qword [r12], r15
    mov     rax, r15
    jmp     .ret

.err_close:
    mov     rdi, r14
    call    file_close
.err:
    mov     rax, -1
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================
; schema_serialize(field_vals_array, field_count, out_buf)
;
; Joins field value C-strings with '|' into out_buf.
; field_vals_array is char*[field_count] — array of pointers.
;
; rdi = pointer to array of char* (field value pointers)
; rsi = field_count
; rdx = output buffer
; Returns: rax = total bytes written to out_buf (not null-terminated)
; ============================================================
schema_serialize:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     rbx, rdi            ; rbx = field_vals_array
    mov     r12, rsi            ; r12 = field_count
    mov     r13, rdx            ; r13 = out_buf
    xor     r14, r14            ; r14 = field index
    xor     r15, r15            ; r15 = bytes written

.next_field:
    cmp     r14, r12
    jge     .ser_done

    ; write '|' separator before all fields except the first
    cmp     r14, 0
    je      .no_delim
    mov     byte [r13 + r15], FIELD_DELIM
    inc     r15
.no_delim:

    ; get pointer to this field's value string
    mov     rdi, [rbx + r14 * 8]   ; rdi = field_vals_array[r14]

    ; copy bytes until null
.copy_field:
    movzx   rax, byte [rdi]
    cmp     rax, 0
    je      .field_done
    mov     byte [r13 + r15], al
    inc     r15
    inc     rdi
    cmp     r15, MAX_RECORD_VAL_LEN - 1
    jge     .ser_done
    jmp     .copy_field

.field_done:
    inc     r14
    jmp     .next_field

.ser_done:
    mov     rax, r15            ; return byte count
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================
; schema_print_record(val_buf, val_len, names_array, field_count)
;
; Splits val_buf on '|', prints "fieldname: value\n" per field.
; Uses SYS_WRITE directly to stdout.
;
; rdi = val_buf
; rsi = val_len
; rdx = names_array (flat array, MAX_FIELD_NAME_LEN bytes per slot)
; rcx = field_count
; ============================================================
schema_print_record:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     rbx, rdi            ; rbx = val_buf (scan ptr)
    mov     r12, rsi            ; r12 = val_len remaining
    mov     r13, rdx            ; r13 = names_array
    mov     r14, rcx            ; r14 = field_count
    xor     r15, r15            ; r15 = field index

.next_pr_field:
    cmp     r15, r14
    jge     .pr_done
    cmp     r12, 0
    jle     .pr_done

    ; print field name
    mov     rdi, r15
    imul    rdi, rdi, MAX_FIELD_NAME_LEN
    add     rdi, r13            ; rdi = name slot

    ; find name length
    xor     rcx, rcx
.name_len:
    cmp     byte [rdi + rcx], 0
    je      .name_len_done
    inc     rcx
    jmp     .name_len
.name_len_done:
    ; write name: SYS_WRITE(STDOUT, name_ptr, len)
    mov     rax, SYS_WRITE
    mov     rsi, rdi
    mov     rdi, STDOUT
    mov     rdx, rcx
    syscall

    ; write ": "
    mov     rax, SYS_WRITE
    mov     rdi, STDOUT
    lea     rsi, [colon_space]
    mov     rdx, colon_sp_len
    syscall

    ; scan val_buf from rbx until '|' or end → this field's value
    mov     rbp, rbx            ; rbp = start of this field's value
    xor     rcx, rcx            ; rcx = field value length
.scan_field:
    cmp     rcx, r12
    jge     .field_end
    movzx   rax, byte [rbx]
    cmp     rax, FIELD_DELIM
    je      .field_end
    inc     rbx
    inc     rcx
    jmp     .scan_field
.field_end:
    ; CRITICAL: syscall clobbers rcx (kernel uses it for return address).
    ; Save field length into r8 (caller-saved but we own this frame entirely)
    ; before any syscall, then use r8 for the advance calculation.
    mov     r8, rcx             ; r8 = field value byte count (survives syscalls)

    ; write field value
    mov     rax, SYS_WRITE
    mov     rdi, STDOUT
    mov     rsi, rbp
    mov     rdx, r8
    syscall

    ; write newline
    mov     rax, SYS_WRITE
    mov     rdi, STDOUT
    lea     rsi, [newline]
    mov     rdx, 1
    syscall

    ; advance past the '|' delimiter if present
    sub     r12, r8             ; subtract field length (not rcx which is garbage)
    cmp     r12, 0
    jle     .pr_done
    movzx   rax, byte [rbx]
    cmp     rax, FIELD_DELIM
    jne     .no_skip_delim
    inc     rbx
    dec     r12
.no_skip_delim:

    inc     r15
    jmp     .next_pr_field

.pr_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================
; schema_format_json(val_buf, val_len, names_array, field_count, out_buf)
;
; Builds: {"field1":"val1","field2":"val2",...}\n
; in out_buf. Returns byte length.
;
; rdi = val_buf
; rsi = val_len
; rdx = names_array
; rcx = field_count
; r8  = out_buf
; Returns: rax = JSON byte length
; ============================================================
schema_format_json:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     rbx, rdi            ; rbx = val_buf scan ptr
    mov     r12, rsi            ; r12 = val bytes remaining
    mov     r13, rdx            ; r13 = names_array
    mov     r14, rcx            ; r14 = field_count
    mov     r15, r8             ; r15 = out_buf
    xor     rbp, rbp            ; rbp = out_buf offset (bytes written)

    ; opening brace
    mov     byte [r15 + rbp], '{'
    inc     rbp

    xor     rcx, rcx            ; rcx = field index
.json_field:
    cmp     rcx, r14
    jge     .json_close
    cmp     r12, 0
    jle     .json_close

    ; comma before all fields except first
    cmp     rcx, 0
    je      .no_comma
    mov     byte [r15 + rbp], ','
    inc     rbp
.no_comma:

    ; write "  (opening quote for field name)
    mov     byte [r15 + rbp], '"'
    inc     rbp

    ; write field name
    push    rcx
    mov     rdi, rcx
    imul    rdi, rdi, MAX_FIELD_NAME_LEN
    add     rdi, r13            ; rdi = name slot ptr
.copy_fname:
    movzx   rax, byte [rdi]
    cmp     rax, 0
    je      .fname_done
    mov     byte [r15 + rbp], al
    inc     rbp
    inc     rdi
    jmp     .copy_fname
.fname_done:
    pop     rcx

    ; write ":" and opening value quote
    mov     byte [r15 + rbp], '"'
    inc     rbp
    mov     byte [r15 + rbp], ':'
    inc     rbp
    mov     byte [r15 + rbp], '"'
    inc     rbp

    ; scan val_buf: copy until '|' or end
    push    rcx
    xor     rdx, rdx            ; rdx = field value length counter
.copy_fval:
    cmp     rdx, r12
    jge     .fval_done
    movzx   rax, byte [rbx]
    cmp     rax, FIELD_DELIM
    je      .fval_done
    mov     byte [r15 + rbp], al
    inc     rbp
    inc     rbx
    inc     rdx
    jmp     .copy_fval
.fval_done:
    sub     r12, rdx
    ; skip '|' if present
    cmp     r12, 0
    jle     .no_pipe_skip
    movzx   rax, byte [rbx]
    cmp     rax, FIELD_DELIM
    jne     .no_pipe_skip
    inc     rbx
    dec     r12
.no_pipe_skip:
    pop     rcx

    ; closing value quote
    mov     byte [r15 + rbp], '"'
    inc     rbp

    inc     rcx
    jmp     .json_field

.json_close:
    mov     byte [r15 + rbp], '}'
    inc     rbp
    mov     byte [r15 + rbp], 0x0A
    inc     rbp

    mov     rax, rbp            ; return length
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
; ============================================================
; main.asm — program entry point, argument parsing, dispatch
; ============================================================
; This is the first code that runs. The Linux kernel jumps to
; _start with the stack set up as:
;
;   [rsp+0 ] = argc          (int64, number of arguments)
;   [rsp+8 ] = argv[0]       (pointer to "tinydb\0")
;   [rsp+16] = argv[1]       (pointer to "SET\0" / "GET\0" / "DEL\0")
;   [rsp+24] = argv[2]       (pointer to key string)
;   [rsp+32] = argv[3]       (pointer to value string, SET only)
;
; Our job:
;   1. Load argc and argv from the stack
;   2. Validate argument count
;   3. Dispatch to cmd_set / cmd_get / cmd_del
;   4. Exit cleanly

%include "include/constants.inc"
%include "include/utils.inc"
%include "include/storage.inc"
%include "include/index.inc"

; Declare the command handler functions we'll implement
; (defined later in this file)
; index/storage functions come from their respective .asm files

section .data

; ── string literals ──────────────────────────────────────────
; db defines byte sequences. Backtick strings support \n escape.
; We define length constants alongside each string so we don't
; have to call str_len on static strings (we know their lengths
; at assemble time).

cmd_SET:        db "SET", 0
cmd_GET:        db "GET", 0
cmd_DEL:        db "DEL", 0

msg_usage:      db "Usage: tinydb SET <key> <value>", 0x0A
                db "       tinydb GET <key>", 0x0A
                db "       tinydb DEL <key>", 0x0A
msg_usage_len   equ $ - msg_usage   ; $ = current address, so this = length

msg_err_cmd:    db "Error: unknown command", 0x0A
msg_err_cmd_len equ $ - msg_err_cmd

msg_err_set:    db "Error: SET requires exactly 3 arguments", 0x0A
msg_err_set_len equ $ - msg_err_set

msg_err_get:    db "Error: GET requires exactly 2 arguments", 0x0A
msg_err_get_len equ $ - msg_err_get

msg_err_del:    db "Error: DEL requires exactly 2 arguments", 0x0A
msg_err_del_len equ $ - msg_err_del

msg_not_found:  db "(nil)", 0x0A
msg_not_found_len equ $ - msg_not_found

msg_ok:         db "OK", 0x0A
msg_ok_len      equ $ - msg_ok

msg_deleted:    db "DEL 1", 0x0A
msg_deleted_len equ $ - msg_deleted

msg_del_miss:   db "DEL 0", 0x0A
msg_del_miss_len equ $ - msg_del_miss

msg_err_write:  db "Error: write failed", 0x0A
msg_err_write_len equ $ - msg_err_write

; ── BSS: uninitialised buffers ────────────────────────────────
; .bss is zero-filled at program load. No disk space used.
; We declare them here so they have a fixed address at link time.

section .bss

; Buffer for index_find result — one full index record (80 bytes)
index_record:   resb INDEX_RECORD_SIZE

; Buffer for reading values from data.db
value_buf:      resb MAX_VAL_LEN


; ============================================================
section .text

global _start


; ────────────────────────────────────────────────────────────
; _start — kernel hands control here
;
; Register plan:
;   rbx = argc
;   r12 = base of argv array (points to argv[0])
;   r13 = argv[1] (command string: "SET"/"GET"/"DEL")
;   r14 = argv[2] (key)
;   r15 = argv[3] (value, only for SET)
;
; We use callee-saved registers (rbx, r12–r15) so that any
; function we call cannot legally clobber them.
; ────────────────────────────────────────────────────────────
_start:
    ; ── 1. Load argc and argv from the stack ─────────────────
    mov     rbx, [rsp]          ; rbx = argc
                                ; [rsp] dereferences the stack pointer
                                ; The kernel put argc here before jumping to us

    lea     r12, [rsp + 8]      ; r12 = &argv[0]
                                ; lea = Load Effective Address
                                ; rsp+8 is where argv[0] pointer lives
                                ; We store the BASE of the array, not argv[0] itself

    ; ── 2. Validate: need at least 3 args (tinydb CMD key) ───
    ; argc < 3 means user ran just "tinydb" or "tinydb SET"
    cmp     rbx, 3
    jl      .usage              ; signed less-than jump

    ; ── 3. Load argv[1] = command ────────────────────────────
    mov     r13, [r12 + 8]      ; r13 = argv[1] = pointer to command string
                                ; r12 points to argv[0], so r12+8 is argv[1]
                                ; Each pointer is 8 bytes on 64-bit Linux

    mov     r14, [r12 + 16]     ; r14 = argv[2] = key pointer

    ; argv[3] only exists for SET — load it regardless,
    ; we'll only use it after confirming the command is SET
    ; and argc == 4. If argc < 4, r15 is just a garbage pointer
    ; we never dereference.
    cmp     rbx, 4
    jl      .skip_argv3
    mov     r15, [r12 + 24]     ; r15 = argv[3] = value pointer
.skip_argv3:

    ; ── 4. Dispatch on command string ────────────────────────
    ; strcmp(argv[1], "SET")
    mov     rdi, r13            ; rdi = argv[1]
    mov     rsi, cmd_SET        ; rsi = "SET"
    call    str_cmp
    test    rax, rax            ; rax==0 means equal
    jz      .do_set

    ; strcmp(argv[1], "GET")
    mov     rdi, r13
    mov     rsi, cmd_GET
    call    str_cmp
    test    rax, rax
    jz      .do_get

    ; strcmp(argv[1], "DEL")
    mov     rdi, r13
    mov     rsi, cmd_DEL
    call    str_cmp
    test    rax, rax
    jz      .do_del

    ; No match — unknown command
    jmp     .unknown_cmd

; ── Command handlers ─────────────────────────────────────────

.do_set:
    ; SET requires exactly 4 args: tinydb SET key value
    cmp     rbx, 4
    jne     .err_set_args

    ; Compute key length
    mov     rdi, r14            ; rdi = key pointer
    call    str_len
    mov     rbx, rax            ; rbx = key_len (save it)

    ; Compute value length
    mov     rdi, r15            ; rdi = value pointer
    call    str_len
    mov     r13, rax            ; r13 = val_len

    ; Step A: Append value to data.db
    ; storage_append(value_ptr, value_len) → rax = data offset
    mov     rdi, r15            ; rdi = value pointer
    mov     rsi, r13            ; rsi = value length
    call    storage_append
    cmp     rax, -1
    je      .err_write
    mov     r12, rax            ; r12 = data offset returned by storage_append

    ; Step B: Write index record
    ; index_put(key_ptr, key_len, data_offset, val_len)
    mov     rdi, r14            ; rdi = key pointer
    mov     rsi, rbx            ; rsi = key_len
    mov     rdx, r12            ; rdx = data offset
    mov     rcx, r13            ; rcx = val_len
    call    index_put
    cmp     rax, -1
    je      .err_write

    ; Print "OK"
    mov     rdi, msg_ok
    mov     rsi, msg_ok_len
    call    print_str
    jmp     .exit_ok

.do_get:
    ; GET requires exactly 3 args: tinydb GET key
    cmp     rbx, 3
    jne     .err_get_args

    ; Compute key length
    mov     rdi, r14
    call    str_len
    mov     r13, rax            ; r13 = key_len

    ; Search index.db for this key
    ; index_find(key_ptr, key_len, result_buf) → rax=0 found, -1 not found
    mov     rdi, r14            ; key pointer
    mov     rsi, r13            ; key_len
    mov     rdx, index_record   ; buffer to receive the 80-byte record
    call    index_find
    cmp     rax, -1
    je      .not_found

    ; Extract offset and val_len from the result record
    ; index_record layout: [0]=key_len, [1..63]=key, [64]=offset(8B), [72]=val_len(4B), [76]=deleted
    mov     rdi, [index_record + INDEX_OFF_OFFSET]      ; rdi = data offset (8 bytes)
    mov     esi, dword [index_record + INDEX_OFF_VALLEN]; esi = val_len; writing esi zero-extends to rsi

    ; Read value from data.db
    ; storage_read(offset, buffer, max_len) → rax = bytes read
    mov     rdx, value_buf      ; rdx = output buffer
    call    storage_read
    cmp     rax, -1
    je      .not_found

    ; Print the value followed by newline
    mov     rdi, value_buf
    mov     rsi, rax            ; rax = bytes read = value length
    call    print_str
    call    print_newline
    jmp     .exit_ok

.do_del:
    ; DEL requires exactly 3 args: tinydb DEL key
    cmp     rbx, 3
    jne     .err_del_args

    ; Compute key length
    mov     rdi, r14
    call    str_len
    mov     r13, rax

    ; index_delete(key_ptr, key_len) → rax=0 deleted, -1 not found
    mov     rdi, r14
    mov     rsi, r13
    call    index_delete
    cmp     rax, -1
    je      .del_miss

    ; Print "DEL 1" (Redis-style: number of keys deleted)
    mov     rdi, msg_deleted
    mov     rsi, msg_deleted_len
    call    print_str
    jmp     .exit_ok

; ── Error / edge case handlers ───────────────────────────────

.not_found:
    mov     rdi, msg_not_found
    mov     rsi, msg_not_found_len
    call    print_str
    jmp     .exit_ok            ; not finding a key is not a program error

.del_miss:
    mov     rdi, msg_del_miss
    mov     rsi, msg_del_miss_len
    call    print_str
    jmp     .exit_ok

.usage:
    mov     rdi, msg_usage
    mov     rsi, msg_usage_len
    call    print_err
    jmp     .exit_err

.unknown_cmd:
    mov     rdi, msg_err_cmd
    mov     rsi, msg_err_cmd_len
    call    print_err
    jmp     .exit_err

.err_set_args:
    mov     rdi, msg_err_set
    mov     rsi, msg_err_set_len
    call    print_err
    jmp     .exit_err

.err_get_args:
    mov     rdi, msg_err_get
    mov     rsi, msg_err_get_len
    call    print_err
    jmp     .exit_err

.err_del_args:
    mov     rdi, msg_err_del
    mov     rsi, msg_err_del_len
    call    print_err
    jmp     .exit_err

.err_write:
    mov     rdi, msg_err_write
    mov     rsi, msg_err_write_len
    call    print_err
    jmp     .exit_err

; ── Exit paths ───────────────────────────────────────────────
; Syscall: exit(status)
;   rax = SYS_EXIT (60)
;   rdi = exit status code

.exit_ok:
    mov     rdi, EXIT_OK
    mov     rax, SYS_EXIT
    syscall

.exit_err:
    mov     rdi, EXIT_ERR
    mov     rax, SYS_EXIT
    syscall
; ============================================================
; main.asm — CLI frontend with schema support
; ============================================================
; Commands:
;   tinydb INIT <count> <f1> <f2> ... <fN>
;   tinydb INSERT <id> <v1> <v2> ... <vN>
;   tinydb GET <id>
;   tinydb DEL <id>

%include "include/constants.inc"
%include "include/utils.inc"
%include "include/storage.inc"
%include "include/index.inc"
%include "include/schema.inc"

section .data

cmd_INIT:       db "INIT",   0
cmd_INSERT:     db "INSERT", 0
cmd_GET:        db "GET",    0
cmd_DEL:        db "DEL",    0

msg_usage:
    db "Usage:", 0x0A
    db "  tinydb INIT <count> <field1> <field2> ...", 0x0A
    db "  tinydb INSERT <id> <val1> <val2> ...", 0x0A
    db "  tinydb GET <id>", 0x0A
    db "  tinydb DEL <id>", 0x0A
msg_usage_len   equ $ - msg_usage

msg_ok:         db "OK", 0x0A
msg_ok_len      equ $ - msg_ok

msg_not_found:  db "(nil)", 0x0A
msg_not_found_len equ $ - msg_not_found

msg_deleted:    db "DEL 1", 0x0A
msg_deleted_len equ $ - msg_deleted

msg_del_miss:   db "DEL 0", 0x0A
msg_del_miss_len equ $ - msg_del_miss

msg_err_cmd:    db "Error: unknown command", 0x0A
msg_err_cmd_len equ $ - msg_err_cmd

msg_err_write:  db "Error: write failed", 0x0A
msg_err_write_len equ $ - msg_err_write

msg_err_schema: db "Error: schema not initialized (run INIT first)", 0x0A
msg_err_schema_len equ $ - msg_err_schema

msg_err_fields: db "Error: wrong number of field values", 0x0A
msg_err_fields_len equ $ - msg_err_fields

msg_err_argc:   db "Error: wrong number of arguments", 0x0A
msg_err_argc_len equ $ - msg_err_argc

section .bss

index_record:   resb INDEX_RECORD_SIZE
value_buf:      resb MAX_VAL_LEN
schema_field_count: resq 1
schema_names:   resb MAX_SCHEMA_FIELDS * MAX_FIELD_NAME_LEN
field_val_ptrs: resq MAX_SCHEMA_FIELDS
serial_buf:     resb MAX_RECORD_VAL_LEN
init_names_buf: resb MAX_SCHEMA_FIELDS * MAX_FIELD_NAME_LEN

section .text

global _start

_start:
    mov     rbx, [rsp]
    lea     r12, [rsp + 8]

    cmp     rbx, 2
    jl      .usage

    mov     r13, [r12 + 8]      ; argv[1] = command

    mov     rdi, r13
    mov     rsi, cmd_INIT
    call    str_cmp
    test    rax, rax
    jz      .do_init

    mov     rdi, r13
    mov     rsi, cmd_INSERT
    call    str_cmp
    test    rax, rax
    jz      .do_insert

    mov     rdi, r13
    mov     rsi, cmd_GET
    call    str_cmp
    test    rax, rax
    jz      .do_get

    mov     rdi, r13
    mov     rsi, cmd_DEL
    call    str_cmp
    test    rax, rax
    jz      .do_del

    jmp     .unknown_cmd

; ============================================================
; INIT <count> <f1> <f2> ... <fN>
; ============================================================
.do_init:
    cmp     rbx, 4
    jl      .err_argc

    mov     r14, [r12 + 16]     ; argv[2] = count string
    xor     r15, r15
    mov     rdi, r14
.parse_count:
    movzx   rax, byte [rdi]
    cmp     rax, '0'
    jl      .count_done
    cmp     rax, '9'
    jg      .count_done
    imul    r15, r15, 10
    sub     rax, '0'
    add     r15, rax
    inc     rdi
    jmp     .parse_count
.count_done:

    lea     rax, [r15 + 3]
    cmp     rbx, rax
    jne     .err_fields

    ; build space-separated names string into init_names_buf
    lea     rdi, [init_names_buf]
    xor     r14, r14            ; offset into init_names_buf
    xor     rcx, rcx
.build_names:
    cmp     rcx, r15
    jge     .names_done
    mov     rax, rcx
    add     rax, 3
    mov     rsi, [r12 + rax * 8]
    cmp     rcx, 0
    je      .no_sp
    mov     byte [rdi + r14], ' '
    inc     r14
.no_sp:
.cp_name:
    movzx   rax, byte [rsi]
    cmp     rax, 0
    je      .cp_done
    mov     byte [rdi + r14], al
    inc     r14
    inc     rsi
    jmp     .cp_name
.cp_done:
    inc     rcx
    jmp     .build_names
.names_done:

    mov     rdi, r15
    lea     rsi, [init_names_buf]
    mov     rdx, r14
    call    schema_init
    cmp     rax, -1
    je      .err_write

    mov     rdi, msg_ok
    mov     rsi, msg_ok_len
    call    print_str
    jmp     .exit_ok

; ============================================================
; INSERT <id> <v1> <v2> ... <vN>
; ============================================================
.do_insert:
    cmp     rbx, 4
    jl      .err_argc

    lea     rdi, [schema_field_count]
    lea     rsi, [schema_names]
    call    schema_load
    cmp     rax, -1
    je      .err_schema
    mov     r15, rax            ; r15 = field_count

    lea     rax, [r15 + 3]
    cmp     rbx, rax
    jne     .err_fields

    mov     r14, [r12 + 16]     ; argv[2] = id (key)

    xor     rcx, rcx
.build_ptrs:
    cmp     rcx, r15
    jge     .ptrs_done
    mov     rax, rcx
    add     rax, 3
    mov     rsi, [r12 + rax * 8]
    mov     [field_val_ptrs + rcx * 8], rsi
    inc     rcx
    jmp     .build_ptrs
.ptrs_done:

    lea     rdi, [field_val_ptrs]
    mov     rsi, r15
    lea     rdx, [serial_buf]
    call    schema_serialize
    mov     r13, rax            ; r13 = serialized length

    mov     rdi, r14
    call    str_len
    mov     rbx, rax            ; rbx = key_len

    lea     rdi, [serial_buf]
    mov     rsi, r13
    call    storage_append
    cmp     rax, -1
    je      .err_write
    mov     r12, rax            ; r12 = data offset

    mov     rdi, r14
    mov     rsi, rbx
    mov     rdx, r12
    mov     rcx, r13
    call    index_put
    cmp     rax, -1
    je      .err_write

    mov     rdi, msg_ok
    mov     rsi, msg_ok_len
    call    print_str
    jmp     .exit_ok

; ============================================================
; GET <id>
; ============================================================
.do_get:
    cmp     rbx, 3
    jne     .err_argc

    mov     r14, [r12 + 16]

    lea     rdi, [schema_field_count]
    lea     rsi, [schema_names]
    call    schema_load
    cmp     rax, -1
    je      .err_schema
    mov     r15, rax

    mov     rdi, r14
    call    str_len
    mov     r13, rax

    mov     rdi, r14
    mov     rsi, r13
    mov     rdx, index_record
    call    index_find
    cmp     rax, -1
    je      .not_found

    mov     rdi, [index_record + INDEX_OFF_OFFSET]
    mov     esi, dword [index_record + INDEX_OFF_VALLEN]
    mov     rdx, value_buf
    call    storage_read
    cmp     rax, -1
    je      .not_found

    mov     rdi, value_buf
    mov     rsi, rax
    lea     rdx, [schema_names]
    mov     rcx, r15
    call    schema_print_record
    jmp     .exit_ok

; ============================================================
; DEL <id>
; ============================================================
.do_del:
    cmp     rbx, 3
    jne     .err_argc

    mov     r14, [r12 + 16]
    mov     rdi, r14
    call    str_len
    mov     r13, rax

    mov     rdi, r14
    mov     rsi, r13
    call    index_delete
    cmp     rax, -1
    je      .del_miss

    mov     rdi, msg_deleted
    mov     rsi, msg_deleted_len
    call    print_str
    jmp     .exit_ok

.not_found:
    mov     rdi, msg_not_found
    mov     rsi, msg_not_found_len
    call    print_str
    jmp     .exit_ok

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

.err_argc:
    mov     rdi, msg_err_argc
    mov     rsi, msg_err_argc_len
    call    print_err
    jmp     .exit_err

.err_fields:
    mov     rdi, msg_err_fields
    mov     rsi, msg_err_fields_len
    call    print_err
    jmp     .exit_err

.err_schema:
    mov     rdi, msg_err_schema
    mov     rsi, msg_err_schema_len
    call    print_err
    jmp     .exit_err

.err_write:
    mov     rdi, msg_err_write
    mov     rsi, msg_err_write_len
    call    print_err
    jmp     .exit_err

.exit_ok:
    mov     rdi, EXIT_OK
    mov     rax, SYS_EXIT
    syscall

.exit_err:
    mov     rdi, EXIT_ERR
    mov     rax, SYS_EXIT
    syscall
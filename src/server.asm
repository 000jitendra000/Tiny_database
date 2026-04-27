; ============================================================
; server.asm — tinydb TCP server with schema support
; ============================================================
; Protocol (newline-terminated):
;   INIT <count> <f1> <f2> ...\n  → OK\n
;   INSERT <id> <v1> <v2> ...\n   → OK\n
;   GET <id>\n                     → field: val\n... | (nil)\n
;   DEL <id>\n                     → DEL 1\n | DEL 0\n

%include "include/constants.inc"
%include "include/network.inc"
%include "include/utils.inc"
%include "include/storage.inc"
%include "include/index.inc"
%include "include/schema.inc"

section .bss

cmd_buf:        resb CMD_BUF_SIZE
index_rec:      resb INDEX_RECORD_SIZE
val_buf:        resb MAX_VAL_LEN
optval:         resd 1
schema_field_count: resq 1
schema_names:   resb MAX_SCHEMA_FIELDS * MAX_FIELD_NAME_LEN
field_val_ptrs: resq MAX_SCHEMA_FIELDS
serial_buf:     resb MAX_RECORD_VAL_LEN
; token pointer array: up to 16+3 tokens (cmd + id + 16 fields)
tok:            resq 20
tok_count:      resq 1

section .data

sockaddr:
    dw  AF_INET
    dw  0x8813              ; port 5000 NBO
    dd  0
    dq  0
sockaddr_len    equ 16

resp_ok:        db "OK", 0x0A
resp_ok_len     equ $ - resp_ok

resp_nil:       db "(nil)", 0x0A
resp_nil_len    equ $ - resp_nil

resp_del1:      db "DEL 1", 0x0A
resp_del1_len   equ $ - resp_del1

resp_del0:      db "DEL 0", 0x0A
resp_del0_len   equ $ - resp_del0

resp_err:       db "ERR bad command", 0x0A
resp_err_len    equ $ - resp_err

resp_err_schema: db "ERR schema not initialized", 0x0A
resp_err_schema_len equ $ - resp_err_schema

resp_err_fields: db "ERR wrong number of fields", 0x0A
resp_err_fields_len equ $ - resp_err_fields

str_INIT:       db "INIT",   0
str_INSERT:     db "INSERT", 0
str_GET:        db "GET",    0
str_DEL:        db "DEL",    0

section .text

global _start

extern str_len
extern str_cmp
extern storage_append
extern storage_read
extern index_put
extern index_find
extern index_delete
extern schema_init
extern schema_load
extern schema_serialize
extern schema_print_record

; ============================================================
_start:
    mov     rdi, AF_INET
    mov     rsi, SOCK_STREAM
    mov     rdx, IPPROTO_TCP
    call    net_socket
    cmp     rax, 0
    jl      .die
    mov     r12, rax

    mov     dword [optval], 1
    mov     rdi, r12
    mov     rsi, SOL_SOCKET
    mov     rdx, SO_REUSEADDR
    lea     rcx, [optval]
    mov     r8,  4
    call    net_setsockopt

    mov     rdi, r12
    lea     rsi, [sockaddr]
    mov     rdx, sockaddr_len
    call    net_bind
    cmp     rax, 0
    jl      .die

    mov     rdi, r12
    mov     rsi, BACKLOG
    call    net_listen
    cmp     rax, 0
    jl      .die

.accept_loop:
    mov     rdi, r12
    xor     rsi, rsi
    xor     rdx, rdx
    call    net_accept
    cmp     rax, 0
    jl      .accept_loop
    mov     r13, rax            ; r13 = client fd

.client_loop:
    mov     rdi, r13
    lea     rsi, [cmd_buf]
    mov     rdx, CMD_BUF_SIZE - 1
    call    net_read
    cmp     rax, 1
    jl      .close_client
    mov     byte [cmd_buf + rax], 0

    ; truncate at first \n
    lea     rcx, [cmd_buf]
.find_nl:
    movzx   rax, byte [rcx]
    cmp     rax, 0
    je      .nl_done
    cmp     rax, 0x0A
    jne     .nl_next
    mov     byte [rcx], 0   ; null the \n itself
    ; also strip a trailing \r if present
    cmp     rcx, cmd_buf
    je      .nl_done
    movzx   rax, byte [rcx - 1]
    cmp     rax, 0x0D
    jne     .nl_done
    mov     byte [rcx - 1], 0
    jmp     .nl_done
.nl_next:
    inc     rcx
    jmp     .find_nl
.nl_done:

    ; ── tokenize cmd_buf in-place ────────────────────────────
    ; Split on spaces/\r\n, store pointers in tok[], count in tok_count.
    ; Max 20 tokens.
    xor     rbx, rbx            ; rbx = tok index
    lea     rcx, [cmd_buf]      ; rcx = scan ptr
    mov     qword [tok_count], 0

.tok_skip_ws:
    movzx   rax, byte [rcx]
    cmp     rax, 0
    je      .tok_done
    cmp     rax, ' '
    je      .tok_skip_inc
    cmp     rax, 0x0D
    je      .tok_skip_inc
    cmp     rax, 0x0A
    je      .tok_skip_inc
    jmp     .tok_start
.tok_skip_inc:
    inc     rcx
    jmp     .tok_skip_ws

.tok_start:
    cmp     rbx, 20
    jge     .tok_done
    mov     [tok + rbx * 8], rcx    ; store token start
    inc     rbx
.tok_scan:
    movzx   rax, byte [rcx]
    cmp     rax, 0
    je      .tok_done
    cmp     rax, ' '
    je      .tok_end
    cmp     rax, 0x0D
    je      .tok_end
    cmp     rax, 0x0A
    je      .tok_end
    inc     rcx
    jmp     .tok_scan
.tok_end:
    mov     byte [rcx], 0       ; null-terminate this token
    inc     rcx
    jmp     .tok_skip_ws
.tok_done:
    mov     qword [tok_count], rbx

    ; need at least 1 token (command)
    cmp     rbx, 1
    jl      .bad_cmd

    ; dispatch on tok[0]
    mov     rdi, [tok]
    mov     rsi, str_INIT
    call    str_cmp
    test    rax, rax
    jz      .do_init

    mov     rdi, [tok]
    mov     rsi, str_INSERT
    call    str_cmp
    test    rax, rax
    jz      .do_insert

    mov     rdi, [tok]
    mov     rsi, str_GET
    call    str_cmp
    test    rax, rax
    jz      .do_get

    mov     rdi, [tok]
    mov     rsi, str_DEL
    call    str_cmp
    test    rax, rax
    jz      .do_del

    jmp     .bad_cmd

; ── INIT ─────────────────────────────────────────────────────
; Tokens: INIT <count> <f1> <f2> ...
; tok[0]=INIT, tok[1]=count, tok[2..]=field names
.do_init:
    mov     rbx, qword [tok_count]
    cmp     rbx, 3
    jl      .bad_cmd

    ; parse count from tok[1]
    mov     rdi, [tok + 8]
    xor     r15, r15
.ini_cnt:
    movzx   rax, byte [rdi]
    cmp     rax, '0'
    jl      .ini_cnt_done
    cmp     rax, '9'
    jg      .ini_cnt_done
    imul    r15, r15, 10
    sub     rax, '0'
    add     r15, rax
    inc     rdi
    jmp     .ini_cnt
.ini_cnt_done:
    ; expect tok_count = 2 + field_count
    lea     rax, [r15 + 2]
    cmp     rbx, rax
    jne     .send_err_fields

    ; build space-separated names from tok[2..]
    lea     rdi, [serial_buf]   ; reuse serial_buf as scratch
    xor     r14, r14            ; offset
    xor     rcx, rcx
.ini_names:
    cmp     rcx, r15
    jge     .ini_names_done
    mov     rax, rcx
    add     rax, 2
    mov     rsi, [tok + rax * 8]
    cmp     rcx, 0
    je      .ini_no_sp
    mov     byte [rdi + r14], ' '
    inc     r14
.ini_no_sp:
.ini_cp:
    movzx   rax, byte [rsi]
    cmp     rax, 0
    je      .ini_cp_done
    mov     byte [rdi + r14], al
    inc     r14
    inc     rsi
    jmp     .ini_cp
.ini_cp_done:
    inc     rcx
    jmp     .ini_names
.ini_names_done:

    mov     rdi, r15
    lea     rsi, [serial_buf]
    mov     rdx, r14
    call    schema_init
    cmp     rax, -1
    je      .send_err

    mov     rdi, r13
    lea     rsi, [resp_ok]
    mov     rdx, resp_ok_len
    call    net_write
    jmp     .client_loop

; ── INSERT ───────────────────────────────────────────────────
; Tokens: INSERT <id> <v1> <v2> ...
.do_insert:
    lea     rdi, [schema_field_count]
    lea     rsi, [schema_names]
    call    schema_load
    cmp     rax, -1
    je      .send_err_schema
    mov     r15, rax

    mov     rbx, qword [tok_count]
    lea     rax, [r15 + 2]
    cmp     rbx, rax
    jne     .send_err_fields


    mov     r14, [tok + 8]      ; r14 = id (key)

    ; build field_val_ptrs from tok[2..]
    xor     rcx, rcx
.ins_ptrs:
    cmp     rcx, r15
    jge     .ins_ptrs_done
    mov     rax, rcx
    add     rax, 2
    mov     rsi, [tok + rax * 8]
    mov     [field_val_ptrs + rcx * 8], rsi
    inc     rcx
    jmp     .ins_ptrs
.ins_ptrs_done:

    lea     rdi, [field_val_ptrs]
    mov     rsi, r15
    lea     rdx, [serial_buf]
    call    schema_serialize
    ; val_len is in rax. r11 is CALLER-SAVED and clobbered by every
    ; Linux syscall (kernel uses r11 to save RFLAGS via syscall/sysret).
    ; Save val_len on the stack so it survives str_len+storage_append.
    push    rax                 ; [rsp+0] = val_len

    mov     rdi, r14
    call    str_len             ; str_len uses no syscalls, safe
    push    rax                 ; [rsp+0] = key_len, [rsp+8] = val_len

    lea     rdi, [serial_buf]
    mov     rsi, [rsp + 8]      ; val_len from stack
    call    storage_append      ; makes syscalls — would trash r11
    cmp     rax, -1
    je      .ins_err            ; unwind stack before error
    mov     rbp, rax            ; rbp = data offset

    pop     r10                 ; r10 = key_len
    pop     r11                 ; r11 = val_len (original rax from schema_serialize)

    mov     rdi, r14
    mov     rsi, r10
    mov     rdx, rbp
    mov     rcx, r11            ; val_len — now correct
    call    index_put
    cmp     rax, -1
    je      .send_err

    mov     rdi, r13
    lea     rsi, [resp_ok]
    mov     rdx, resp_ok_len
    call    net_write
    jmp     .client_loop

; ── GET ──────────────────────────────────────────────────────
.do_get:
    mov     rbx, qword [tok_count]
    cmp     rbx, 2
    jne     .bad_cmd

    lea     rdi, [schema_field_count]
    lea     rsi, [schema_names]
    call    schema_load
    cmp     rax, -1
    je      .send_err_schema
    mov     r15, rax

    mov     r14, [tok + 8]      ; id
    mov     rdi, r14
    call    str_len
    mov     r10, rax

    mov     rdi, r14
    mov     rsi, r10
    lea     rdx, [index_rec]
    call    index_find
    cmp     rax, -1
    je      .send_nil

    mov     rdi, [index_rec + INDEX_OFF_OFFSET]
    mov     esi, dword [index_rec + INDEX_OFF_VALLEN]
    lea     rdx, [val_buf]
    call    storage_read
    cmp     rax, -1
    je      .send_nil
    mov     r10, rax            ; r10 = val bytes read

    ; schema_print_record writes directly to stdout — for TCP we need
    ; to write to the client fd instead. We build the output into serial_buf
    ; then send it. Use schema_format_json? No — user wants text format.
    ; We implement inline field printing to the client fd here.

    ; Serialize the structured record to serial_buf as text:
    ; "name: jitendra\nage: 20\ncity: vizag\n"
    ; then send the whole buffer in one write.
    ; This avoids all register-clobber-across-call issues.
    ;
    ; We use serial_buf (MAX_RECORD_VAL_LEN bytes) as output.
    ; Registers: rbx=val scan ptr, rbp=remaining bytes,
    ;            r11=output buf ptr, r8=output offset,
    ;            rcx=field index.

    lea     rbx, [val_buf]      ; rbx = val scan ptr
    mov     rbp, r10            ; rbp = remaining val bytes
    lea     r11, [serial_buf]   ; r11 = output buffer base
    xor     r8, r8              ; r8  = bytes written to serial_buf
    xor     rcx, rcx            ; rcx = field index

.get_build_field:
    cmp     rcx, r15
    jge     .get_build_done
    cmp     rbp, 0
    jle     .get_build_done

    ; copy field name into serial_buf
    push    rcx
    mov     rdi, rcx
    imul    rdi, rdi, MAX_FIELD_NAME_LEN
    lea     rsi, [schema_names + rdi]   ; rsi = name ptr
.gb_name:
    movzx   rax, byte [rsi]
    cmp     rax, 0
    je      .gb_name_done
    mov     byte [r11 + r8], al
    inc     r8
    inc     rsi
    jmp     .gb_name
.gb_name_done:
    ; copy ": "
    mov     byte [r11 + r8], ':'
    inc     r8
    mov     byte [r11 + r8], ' '
    inc     r8

    ; copy field value until '|' or end
    xor     rdx, rdx            ; rdx = field value length
.gb_val:
    cmp     rdx, rbp
    jge     .gb_val_done
    movzx   rax, byte [rbx]
    cmp     rax, '|'
    je      .gb_val_done
    mov     byte [r11 + r8], al
    inc     r8
    inc     rbx
    inc     rdx
    jmp     .gb_val
.gb_val_done:
    ; copy newline
    mov     byte [r11 + r8], 0x0A
    inc     r8

    ; advance val position
    sub     rbp, rdx
    cmp     rbp, 0
    jle     .gb_next
    movzx   rax, byte [rbx]
    cmp     rax, '|'
    jne     .gb_next
    inc     rbx
    dec     rbp
.gb_next:
    pop     rcx
    inc     rcx
    jmp     .get_build_field

.get_build_done:
    ; send the entire assembled text in one net_write
    mov     rdi, r13
    lea     rsi, [serial_buf]
    mov     rdx, r8
    call    net_write
    jmp     .client_loop

; ── DEL ──────────────────────────────────────────────────────
.do_del:
    mov     rbx, qword [tok_count]
    cmp     rbx, 2
    jne     .bad_cmd

    mov     r14, [tok + 8]
    mov     rdi, r14
    call    str_len
    mov     r10, rax

    mov     rdi, r14
    mov     rsi, r10
    call    index_delete
    cmp     rax, -1
    je      .send_del0

    mov     rdi, r13
    lea     rsi, [resp_del1]
    mov     rdx, resp_del1_len
    call    net_write
    jmp     .client_loop

.send_del0:
    mov     rdi, r13
    lea     rsi, [resp_del0]
    mov     rdx, resp_del0_len
    call    net_write
    jmp     .client_loop

.send_nil:
    mov     rdi, r13
    lea     rsi, [resp_nil]
    mov     rdx, resp_nil_len
    call    net_write
    jmp     .client_loop

.send_err_schema:
    mov     rdi, r13
    lea     rsi, [resp_err_schema]
    mov     rdx, resp_err_schema_len
    call    net_write
    jmp     .client_loop

.send_err_fields:
    mov     rdi, r13
    lea     rsi, [resp_err_fields]
    mov     rdx, resp_err_fields_len
    call    net_write
    jmp     .client_loop

.ins_err:
    add     rsp, 16         ; discard key_len+val_len before error
.bad_cmd:
.send_err:
    mov     rdi, r13
    lea     rsi, [resp_err]
    mov     rdx, resp_err_len
    call    net_write
    jmp     .client_loop

.close_client:
    mov     rdi, r13
    call    net_close
    jmp     .accept_loop

.die:
    mov     rdi, EXIT_ERR
    mov     rax, SYS_EXIT
    syscall

; ── static data needed by GET print loop ─────────────────────
section .data
colon_sp:   db ": "
nl_byte:    db 0x0A




; dispatch on tok[0]
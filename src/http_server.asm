; ============================================================
; http_server.asm — tinydb HTTP frontend with schema support
; ============================================================
; Routes:
;   POST /init    body: count=3&fields=name age city
;   GET  /get?id=<id>          → {"name":"v","age":"v","city":"v"}
;   POST /insert  body: id=1&name=jitendra&age=20&city=vizag
;   POST /del     body: id=<id>

%include "include/constants.inc"
%include "include/network.inc"
%include "include/http.inc"
%include "include/storage.inc"
%include "include/index.inc"
%include "include/schema.inc"

extern net_socket
extern net_bind
extern net_listen
extern net_accept
extern net_read
extern net_close
extern net_setsockopt

extern http_parse_method
extern http_parse_route
extern http_find_body
extern http_parse_query_param   ; new: generic param extractor
extern http_parse_post_key      ; for id= field
extern http_parse_post_param    ; new: generic POST param extractor

extern http_respond_200_json
extern http_respond_404_json
extern http_respond_400_json

extern storage_append
extern storage_read
extern index_put
extern index_find
extern index_delete
extern schema_init
extern schema_load
extern schema_serialize
extern schema_format_json

extern str_len

section .data

http_sockaddr:
    dw  AF_INET
    dw  HTTP_PORT_NBO
    dd  0
    dq  0
http_sockaddr_len equ 16

json_ok:        db '{"ok":true}', 0x0A
json_ok_len     equ $ - json_ok

json_del1:      db '{"deleted":1}', 0x0A
json_del1_len   equ $ - json_del1

json_del0:      db '{"deleted":0}', 0x0A
json_del0_len   equ $ - json_del0

; route strings for matching
route_init:     db "/init",   0
route_get:      db "/get",    0
route_insert:   db "/insert", 0
route_del:      db "/del",    0

; param name strings
param_id:       db "id",     0
param_count:    db "count",  0
param_fields:   db "fields", 0

; field name strings for INSERT parsing (up to MAX_SCHEMA_FIELDS)
; We load schema to get field names, then look up each one in the POST body.

section .bss

req_buf:        resb HTTP_BUF_SIZE
id_buf:         resb MAX_KEY_LEN + 1
val_buf:        resb HTTP_VAL_BUF
index_rec:      resb INDEX_RECORD_SIZE
json_buf:       resb HTTP_VAL_BUF + 128
optval:         resd 1

schema_field_count: resq 1
schema_names:   resb MAX_SCHEMA_FIELDS * MAX_FIELD_NAME_LEN
field_val_bufs: resb MAX_SCHEMA_FIELDS * MAX_FIELD_NAME_LEN  ; each field value
field_val_ptrs: resq MAX_SCHEMA_FIELDS
serial_buf:     resb MAX_RECORD_VAL_LEN

; scratch for count parsing
count_str_buf:  resb 8
fields_str_buf: resb MAX_SCHEMA_FIELDS * MAX_FIELD_NAME_LEN

section .text
global _start

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
    lea     rsi, [http_sockaddr]
    mov     rdx, http_sockaddr_len
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
    mov     r13, rax

    mov     rdi, r13
    lea     rsi, [req_buf]
    mov     rdx, HTTP_BUF_SIZE - 1
    call    net_read
    cmp     rax, 1
    jl      .close_client
    mov     byte [req_buf + rax], 0

    ; parse method
    lea     rdi, [req_buf]
    call    http_parse_method
    mov     r14, rax

    ; parse route by scanning path manually (avoid route ID collision with old /set)
    lea     rdi, [req_buf]
    call    http_find_path      ; returns rax=ptr to path start, 0 if none
    test    rax, rax
    jz      .bad_request
    mov     r15, rax            ; r15 = path pointer

    ; match routes
    mov     rdi, r15
    mov     rsi, route_init
    call    http_starts_with
    test    rax, rax
    jnz     .handle_init

    mov     rdi, r15
    mov     rsi, route_get
    call    http_starts_with
    test    rax, rax
    jnz     .handle_get

    mov     rdi, r15
    mov     rsi, route_insert
    call    http_starts_with
    test    rax, rax
    jnz     .handle_insert

    mov     rdi, r15
    mov     rsi, route_del
    call    http_starts_with
    test    rax, rax
    jnz     .handle_del

    jmp     .bad_request

; ============================================================
; POST /init   body: count=3&fields=name age city
; ============================================================
.handle_init:
    lea     rdi, [req_buf]
    mov     rsi, HTTP_BUF_SIZE
    call    http_find_body
    test    rax, rax
    jz      .bad_request
    mov     rbp, rax            ; rbp = body

    ; extract count=<n>
    mov     rdi, rbp
    mov     rsi, param_count
    lea     rdx, [count_str_buf]
    call    http_extract_param
    test    rax, rax
    jz      .bad_request

    ; parse count integer
    lea     rdi, [count_str_buf]
    xor     r15, r15
.init_parse_cnt:
    movzx   rax, byte [rdi]
    cmp     rax, '0'
    jl      .init_cnt_done
    cmp     rax, '9'
    jg      .init_cnt_done
    imul    r15, r15, 10
    sub     rax, '0'
    add     r15, rax
    inc     rdi
    jmp     .init_parse_cnt
.init_cnt_done:

    ; extract fields=<space-separated names>
    mov     rdi, rbp
    mov     rsi, param_fields
    lea     rdx, [fields_str_buf]
    call    http_extract_param
    test    rax, rax
    jz      .bad_request
    mov     rbx, rax            ; rbx = fields string length

    ; schema_init(field_count, names_buf, names_len)
    mov     rdi, r15
    lea     rsi, [fields_str_buf]
    mov     rdx, rbx
    call    schema_init
    cmp     rax, -1
    je      .bad_request

    mov     rdi, r13
    lea     rsi, [json_ok]
    mov     rdx, json_ok_len
    call    http_respond_200_json
    jmp     .close_client

; ============================================================
; GET /get?id=<id>
; ============================================================
.handle_get:
    ; extract id from query string
    lea     rdi, [req_buf]
    mov     rsi, param_id
    lea     rdx, [id_buf]
    call    http_extract_query_param
    test    rax, rax
    jz      .not_found
    mov     rbx, rax            ; rbx = id_len

    ; load schema for JSON field names
    lea     rdi, [schema_field_count]
    lea     rsi, [schema_names]
    call    schema_load
    cmp     rax, -1
    je      .not_found
    mov     r15, rax            ; r15 = field_count

    ; index_find
    lea     rdi, [id_buf]
    mov     rsi, rbx
    lea     rdx, [index_rec]
    call    index_find
    cmp     rax, -1
    je      .not_found

    ; storage_read
    mov     rdi, [index_rec + INDEX_OFF_OFFSET]
    mov     esi, dword [index_rec + INDEX_OFF_VALLEN]
    lea     rdx, [val_buf]
    call    storage_read
    cmp     rax, -1
    je      .not_found
    mov     rbx, rax            ; rbx = val bytes read

    ; schema_format_json(val_buf, val_len, names_array, field_count, out_buf)
    lea     rdi, [val_buf]
    mov     rsi, rbx
    lea     rdx, [schema_names]
    mov     rcx, r15
    lea     r8,  [json_buf]
    call    schema_format_json
    ; rax = json length

    mov     rdx, rax
    mov     rdi, r13
    lea     rsi, [json_buf]
    call    http_respond_200_json
    jmp     .close_client

; ============================================================
; POST /insert  body: id=1&name=jitendra&age=20&city=vizag
; ============================================================
.handle_insert:
    lea     rdi, [req_buf]
    mov     rsi, HTTP_BUF_SIZE
    call    http_find_body
    test    rax, rax
    jz      .bad_request
    mov     rbp, rax            ; rbp = body

    ; load schema to get field names and count
    lea     rdi, [schema_field_count]
    lea     rsi, [schema_names]
    call    schema_load
    cmp     rax, -1
    je      .bad_request
    mov     r15, rax            ; r15 = field_count

    ; extract id
    mov     rdi, rbp
    mov     rsi, param_id
    lea     rdx, [id_buf]
    call    http_extract_param
    test    rax, rax
    jz      .bad_request
    mov     r14, rax            ; r14 = id_len (saved)

    ; extract each field value by name from body
    ; field_val_bufs[i] = flat storage, MAX_FIELD_NAME_LEN bytes per slot
    ; field_val_ptrs[i] = pointer to field_val_bufs[i]
    xor     rcx, rcx
.insert_fields:
    cmp     rcx, r15
    jge     .insert_fields_done

    ; slot address for this field's value output
    push    rcx
    mov     rax, rcx
    imul    rax, rax, MAX_FIELD_NAME_LEN
    lea     rdx, [field_val_bufs + rax]
    mov     [field_val_ptrs + rcx * 8], rdx   ; store pointer

    ; field name pointer
    mov     rax, rcx
    imul    rax, rax, MAX_FIELD_NAME_LEN
    lea     rsi, [schema_names + rax]          ; param name = field name

    mov     rdi, rbp
    ; rdx already set to output buffer
    call    http_extract_param
    ; if not found (rax=0), store empty string — body may omit optional fields
    pop     rcx
    inc     rcx
    jmp     .insert_fields
.insert_fields_done:

    ; schema_serialize(field_val_ptrs, field_count, serial_buf)
    lea     rdi, [field_val_ptrs]
    mov     rsi, r15
    lea     rdx, [serial_buf]
    call    schema_serialize
    ; r11 is clobbered by every Linux syscall — save val_len on stack
    push    rax                 ; [rsp] = val_len

    ; key = id_buf, key_len
    lea     rdi, [id_buf]
    call    str_len             ; no syscalls, safe
    push    rax                 ; [rsp] = key_len, [rsp+8] = val_len

    ; storage_append
    lea     rdi, [serial_buf]
    mov     rsi, [rsp + 8]      ; val_len from stack
    call    storage_append
    cmp     rax, -1
    je      .http_ins_err
    mov     rbx, rax

    pop     r10                 ; r10 = key_len
    pop     r11                 ; r11 = val_len

    ; index_put
    lea     rdi, [id_buf]
    mov     rsi, r10
    mov     rdx, rbx
    mov     rcx, r11
    call    index_put
    cmp     rax, -1
    je      .bad_request

    mov     rdi, r13
    lea     rsi, [json_ok]
    mov     rdx, json_ok_len
    call    http_respond_200_json
    jmp     .close_client

; ============================================================
; POST /del   body: id=<id>
; ============================================================
.handle_del:
    lea     rdi, [req_buf]
    mov     rsi, HTTP_BUF_SIZE
    call    http_find_body
    test    rax, rax
    jz      .bad_request
    mov     rbp, rax

    mov     rdi, rbp
    mov     rsi, param_id
    lea     rdx, [id_buf]
    call    http_extract_param
    test    rax, rax
    jz      .bad_request
    mov     rbx, rax

    lea     rdi, [id_buf]
    mov     rsi, rbx
    call    index_delete
    cmp     rax, -1
    je      .del_miss

    mov     rdi, r13
    lea     rsi, [json_del1]
    mov     rdx, json_del1_len
    call    http_respond_200_json
    jmp     .close_client

.del_miss:
    mov     rdi, r13
    lea     rsi, [json_del0]
    mov     rdx, json_del0_len
    call    http_respond_200_json
    jmp     .close_client

.http_ins_err:
    add     rsp, 16
.not_found:
    mov     rdi, r13
    call    http_respond_404_json
    jmp     .close_client

.bad_request:
    mov     rdi, r13
    call    http_respond_400_json

.close_client:
    mov     rdi, r13
    call    net_close
    jmp     .accept_loop

.die:
    mov     rdi, EXIT_ERR
    mov     rax, SYS_EXIT
    syscall

; ============================================================
; http_find_path — returns pointer to path in request line
; rdi = request buffer
; rax = ptr to '/' of path, or 0
; ============================================================
http_find_path:
.skip:
    movzx   rax, byte [rdi]
    cmp     rax, 0
    je      .none
    cmp     rax, '/'
    je      .found
    inc     rdi
    jmp     .skip
.found:
    mov     rax, rdi
    ret
.none:
    xor     rax, rax
    ret

; ============================================================
; http_starts_with — rdi=str, rsi=prefix → rax=1 if match else 0
; ============================================================
http_starts_with:
.loop:
    movzx   rcx, byte [rsi]
    test    rcx, rcx
    jz      .yes
    movzx   rdx, byte [rdi]
    cmp     rcx, rdx
    jne     .no
    inc     rdi
    inc     rsi
    jmp     .loop
.yes:
    mov     rax, 1
    ret
.no:
    xor     rax, rax
    ret

; ============================================================
; http_extract_param — extract value of named param from body
; Scans for "name=<value>" in body string.
; rdi = body pointer
; rsi = param name (null-terminated)
; rdx = output buffer
; Returns: rax = value length, 0 if not found
; ============================================================
http_extract_param:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     rbx, rdi            ; rbx = body scan ptr
    mov     r12, rsi            ; r12 = param name
    mov     r13, rdx            ; r13 = output buf

.ep_scan:
    movzx   rax, byte [rbx]
    cmp     rax, 0
    je      .ep_not_found

    ; try to match param name at current position
    mov     rdi, rbx
    mov     rsi, r12
    call    http_starts_with
    test    rax, rax
    jz      .ep_next

    ; check that next char after name is '='
    ; compute name length
    mov     rdi, r12
.nm_len:
    movzx   rax, byte [rdi]
    cmp     rax, 0
    je      .nm_len_done
    inc     rdi
    jmp     .nm_len
.nm_len_done:
    sub     rdi, r12            ; rdi = name length
    lea     rax, [rbx + rdi]
    movzx   rcx, byte [rax]
    cmp     rcx, '='
    jne     .ep_next

    ; found "name=", copy value
    inc     rax                 ; skip '='
    xor     r14, r14
.ep_copy:
    movzx   rcx, byte [rax]
    cmp     rcx, 0
    je      .ep_done
    cmp     rcx, '&'
    je      .ep_done
    cmp     rcx, 0x0D
    je      .ep_done
    cmp     rcx, 0x0A
    je      .ep_done
    ; URL decode '+' as space
    cmp     rcx, '+'
    jne     .ep_no_plus
    mov     rcx, ' '
.ep_no_plus:
    mov     byte [r13 + r14], cl
    inc     r14
    inc     rax
    cmp     r14, MAX_RECORD_VAL_LEN - 1
    jge     .ep_done
    jmp     .ep_copy
.ep_done:
    mov     byte [r13 + r14], 0
    mov     rax, r14
    jmp     .ep_ret

.ep_next:
    inc     rbx
    jmp     .ep_scan

.ep_not_found:
    xor     rax, rax
.ep_ret:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; http_extract_query_param — extract ?name=<val> from request line
; rdi = request buffer start
; rsi = param name
; rdx = output buffer
; Returns: rax = value length, 0 if not found
; Stops scanning at first \r or \n (end of request line).
; ============================================================
http_extract_query_param:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx

.qp_scan:
    movzx   rax, byte [rbx]
    cmp     rax, 0
    je      .qp_not_found
    cmp     rax, 0x0D
    je      .qp_not_found
    cmp     rax, 0x0A
    je      .qp_not_found

    mov     rdi, rbx
    mov     rsi, r12
    call    http_starts_with
    test    rax, rax
    jz      .qp_next

    ; check '=' follows
    mov     rdi, r12
.qnl:
    movzx   rax, byte [rdi]
    cmp     rax, 0
    je      .qnl_done
    inc     rdi
    jmp     .qnl
.qnl_done:
    sub     rdi, r12
    lea     rax, [rbx + rdi]
    movzx   rcx, byte [rax]
    cmp     rcx, '='
    jne     .qp_next

    inc     rax
    xor     r14, r14
.qp_copy:
    movzx   rcx, byte [rax]
    cmp     rcx, 0
    je      .qp_done
    cmp     rcx, ' '
    je      .qp_done
    cmp     rcx, '&'
    je      .qp_done
    cmp     rcx, 0x0D
    je      .qp_done
    cmp     rcx, 0x0A
    je      .qp_done
    cmp     rcx, '+'
    jne     .qp_no_plus
    mov     rcx, ' '
.qp_no_plus:
    mov     byte [r13 + r14], cl
    inc     r14
    inc     rax
    cmp     r14, MAX_KEY_LEN
    jge     .qp_done
    jmp     .qp_copy
.qp_done:
    mov     byte [r13 + r14], 0
    mov     rax, r14
    jmp     .qp_ret

.qp_next:
    inc     rbx
    jmp     .qp_scan

.qp_not_found:
    xor     rax, rax
.qp_ret:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
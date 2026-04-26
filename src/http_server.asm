; ============================================================
; http_server.asm — tinydb HTTP frontend
; ============================================================
; Build:  make http
; Run:    ./tinydb-http
;
; Routes:
;   GET  /get?key=<key>         → {"value":"<val>"}
;   POST /set  body: key=<k>&value=<v>  → {"ok":true}
;   POST /del  body: key=<k>    → {"deleted":1} or {"deleted":0}
;
; Architecture:
;   http_server.asm  ← you are here (accept loop + dispatch)
;   http_parser.asm  ← parse method / route / params
;   http_response.asm ← write HTTP responses
;   storage.asm      ← append / read values (unchanged)
;   index.asm        ← put / find / delete records (unchanged)
;   network.asm      ← socket syscall wrappers (unchanged)

%include "include/constants.inc"
%include "include/network.inc"
%include "include/http.inc"
%include "include/storage.inc"
%include "include/index.inc"

; ── externs ──────────────────────────────────────────────────
extern net_socket
extern net_bind
extern net_listen
extern net_accept
extern net_read
extern net_close
extern net_setsockopt

extern http_parse_method
extern http_parse_route
extern http_parse_query_key
extern http_parse_post_key
extern http_parse_post_value
extern http_find_body

extern http_respond_200_json
extern http_respond_404_json
extern http_respond_400_json

extern storage_append
extern storage_read
extern index_put
extern index_find
extern index_delete

; ── data ─────────────────────────────────────────────────────
section .data

; sockaddr_in for port 8080
http_sockaddr:
    dw  AF_INET
    dw  HTTP_PORT_NBO
    dd  0
    dq  0
http_sockaddr_len equ 16

; static JSON response bodies
json_ok:        db '{"ok":true}', 0x0A
json_ok_len     equ $ - json_ok

json_del1:      db '{"deleted":1}', 0x0A
json_del1_len   equ $ - json_del1

json_del0:      db '{"deleted":0}', 0x0A
json_del0_len   equ $ - json_del0

; prefix/suffix for building {"value":"..."} inline
json_val_pre:   db '{"value":"'
json_val_pre_len equ $ - json_val_pre

json_val_suf:   db '"}', 0x0A
json_val_suf_len equ $ - json_val_suf

; ── bss ──────────────────────────────────────────────────────
section .bss

req_buf:        resb HTTP_BUF_SIZE      ; raw HTTP request bytes
key_buf:        resb MAX_KEY_LEN + 1    ; extracted key
val_buf:        resb HTTP_VAL_BUF       ; extracted value (POST) or read value (GET)
index_rec:      resb INDEX_RECORD_SIZE  ; index_find result
json_buf:       resb HTTP_VAL_BUF + 32  ; assembled {"value":"..."} body
optval:         resd 1

; ── text ─────────────────────────────────────────────────────
section .text

global _start

; ============================================================
; _start
; ============================================================
_start:
    ; ── socket ───────────────────────────────────────────────
    mov     rdi, AF_INET
    mov     rsi, SOCK_STREAM
    mov     rdx, IPPROTO_TCP
    call    net_socket
    cmp     rax, 0
    jl      .die
    mov     r12, rax            ; r12 = server fd

    ; ── setsockopt SO_REUSEADDR ──────────────────────────────
    mov     dword [optval], 1
    mov     rdi, r12
    mov     rsi, SOL_SOCKET
    mov     rdx, SO_REUSEADDR
    lea     rcx, [optval]
    mov     r8,  4
    call    net_setsockopt

    ; ── bind ─────────────────────────────────────────────────
    mov     rdi, r12
    lea     rsi, [http_sockaddr]
    mov     rdx, http_sockaddr_len
    call    net_bind
    cmp     rax, 0
    jl      .die

    ; ── listen ───────────────────────────────────────────────
    mov     rdi, r12
    mov     rsi, BACKLOG
    call    net_listen
    cmp     rax, 0
    jl      .die

; ── accept loop ──────────────────────────────────────────────
.accept_loop:
    mov     rdi, r12
    xor     rsi, rsi
    xor     rdx, rdx
    call    net_accept
    cmp     rax, 0
    jl      .accept_loop
    mov     r13, rax            ; r13 = client fd

    ; ── read request ─────────────────────────────────────────
    mov     rdi, r13
    lea     rsi, [req_buf]
    mov     rdx, HTTP_BUF_SIZE - 1
    call    net_read
    cmp     rax, 1
    jl      .close_client
    mov     byte [req_buf + rax], 0     ; null-terminate

    ; ── parse method ─────────────────────────────────────────
    lea     rdi, [req_buf]
    call    http_parse_method
    mov     r14, rax            ; r14 = method id

    ; ── parse route ──────────────────────────────────────────
    lea     rdi, [req_buf]
    call    http_parse_route
    mov     r15, rax            ; r15 = route id

    ; ── dispatch ─────────────────────────────────────────────
    cmp     r14, HTTP_METHOD_GET
    jne     .try_post

    cmp     r15, HTTP_ROUTE_GET_KEY
    je      .handle_get

    jmp     .bad_request

.try_post:
    cmp     r14, HTTP_METHOD_POST
    jne     .bad_request

    cmp     r15, HTTP_ROUTE_SET
    je      .handle_set

    cmp     r15, HTTP_ROUTE_DEL
    je      .handle_del

    jmp     .bad_request

; ============================================================
; GET /get?key=<key>
; ============================================================
.handle_get:
    ; extract key from query string
    lea     rdi, [req_buf]
    lea     rsi, [key_buf]
    call    http_parse_query_key
    test    rax, rax
    jz      .not_found
    mov     rbx, rax            ; rbx = key_len

    ; index_find(key_ptr, key_len, result_buf)
    lea     rdi, [key_buf]
    mov     rsi, rbx
    lea     rdx, [index_rec]
    call    index_find
    cmp     rax, -1
    je      .not_found

    ; storage_read(offset, val_len, out_buf)
    mov     rdi, [index_rec + INDEX_OFF_OFFSET]
    mov     esi, dword [index_rec + INDEX_OFF_VALLEN]
    lea     rdx, [val_buf]
    call    storage_read
    cmp     rax, -1
    je      .not_found
    mov     rbx, rax            ; rbx = bytes read = val_len

    ; build {"value":"<val>"} in json_buf
    ; copy prefix
    lea     rdi, [json_buf]
    lea     rsi, [json_val_pre]
    mov     rcx, json_val_pre_len
    rep movsb

    ; copy value bytes  (rdi already advanced)
    lea     rsi, [val_buf]
    mov     rcx, rbx
    rep movsb

    ; copy suffix
    lea     rsi, [json_val_suf]
    mov     rcx, json_val_suf_len
    rep movsb

    ; total length = prefix + val_len + suffix
    mov     rdx, json_val_pre_len
    add     rdx, rbx
    add     rdx, json_val_suf_len

    mov     rdi, r13
    lea     rsi, [json_buf]
    call    http_respond_200_json
    jmp     .close_client

; ============================================================
; POST /set  body: key=<k>&value=<v>
; ============================================================
.handle_set:
    ; find body start
    lea     rdi, [req_buf]
    mov     rsi, HTTP_BUF_SIZE
    call    http_find_body
    test    rax, rax
    jz      .bad_request
    mov     rbp, rax            ; rbp = body ptr

    ; parse key
    mov     rdi, rbp
    lea     rsi, [key_buf]
    call    http_parse_post_key
    test    rax, rax
    jz      .bad_request
    mov     r8, rax             ; r8 = key_len

    ; parse value
    mov     rdi, rbp
    lea     rsi, [val_buf]
    call    http_parse_post_value
    test    rax, rax
    jz      .bad_request
    mov     r9, rax             ; r9 = val_len

    ; storage_append(val_ptr, val_len) → data offset
    lea     rdi, [val_buf]
    mov     rsi, r9
    call    storage_append
    cmp     rax, -1
    je      .bad_request
    mov     rbx, rax            ; rbx = data offset

    ; index_put(key_ptr, key_len, data_offset, val_len)
    lea     rdi, [key_buf]
    mov     rsi, r8
    mov     rdx, rbx
    mov     rcx, r9
    call    index_put
    cmp     rax, -1
    je      .bad_request

    mov     rdi, r13
    lea     rsi, [json_ok]
    mov     rdx, json_ok_len
    call    http_respond_200_json
    jmp     .close_client

; ============================================================
; POST /del  body: key=<k>
; ============================================================
.handle_del:
    ; find body
    lea     rdi, [req_buf]
    mov     rsi, HTTP_BUF_SIZE
    call    http_find_body
    test    rax, rax
    jz      .bad_request
    mov     rbp, rax

    ; parse key
    mov     rdi, rbp
    lea     rsi, [key_buf]
    call    http_parse_post_key
    test    rax, rax
    jz      .bad_request
    mov     rbx, rax            ; rbx = key_len

    ; index_delete(key_ptr, key_len) → 0=deleted, -1=not found
    lea     rdi, [key_buf]
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

; ── error paths ──────────────────────────────────────────────
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
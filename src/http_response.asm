; ============================================================
; http_response.asm — HTTP response builders
; ============================================================
; Three response types used by http_server.asm:
;
;   http_respond_200_json  — 200 OK  + JSON body
;   http_respond_404_json  — 404 Not Found + JSON body
;   http_respond_400_json  — 400 Bad Request + JSON body
;
; All write directly to the client fd and return.
; Uses net_write from network.asm.

%include "include/constants.inc"
%include "include/network.inc"

; ── itoa_decimal: convert rax (uint64) → decimal string in buf ──
; internal helper, not exported

section .data

; Response headers — Content-Length is always written separately
; so we can handle variable-length JSON bodies.

hdr_200:
    db "HTTP/1.1 200 OK", 0x0D, 0x0A
    db "Content-Type: application/json", 0x0D, 0x0A
    db "Content-Length: "
hdr_200_len     equ $ - hdr_200

hdr_404:
    db "HTTP/1.1 404 Not Found", 0x0D, 0x0A
    db "Content-Type: application/json", 0x0D, 0x0A
    db "Content-Length: "
hdr_404_len     equ $ - hdr_404

hdr_400:
    db "HTTP/1.1 400 Bad Request", 0x0D, 0x0A
    db "Content-Type: application/json", 0x0D, 0x0A
    db "Content-Length: "
hdr_400_len     equ $ - hdr_400

hdr_end:        db 0x0D, 0x0A, 0x0D, 0x0A   ; \r\n\r\n after Content-Length value
hdr_end_len     equ $ - hdr_end

body_404:       db '{"error":"not found"}', 0x0A
body_404_len    equ $ - body_404

body_400:       db '{"error":"bad request"}', 0x0A
body_400_len    equ $ - body_400

section .bss

cl_buf:         resb 24         ; scratch for Content-Length decimal value

section .text

global http_respond_200_json
global http_respond_404_json
global http_respond_400_json

extern net_write


; ── internal: write_all ──────────────────────────────────────
; rdi = fd, rsi = buf, rdx = len
; loops until all bytes written (handles short writes)
write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.loop:
    test    r13, r13
    jz      .done
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    call    net_write
    cmp     rax, 0
    jle     .done               ; error or closed
    add     r12, rax
    sub     r13, rax
    jmp     .loop
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret


; ── internal: uint64_to_dec ──────────────────────────────────
; Convert rdi (uint64) to decimal ASCII in cl_buf.
; Returns rax = pointer to start of string, rcx = length.
; Writes into cl_buf (24 bytes is enough for uint64 max).
uint64_to_dec:
    push    rbx
    push    r12

    lea     rbx, [cl_buf + 23]  ; work from end of buffer
    mov     byte [rbx], 0       ; null terminator
    dec     rbx

    mov     rax, rdi
    mov     r12, 10             ; divisor

    test    rax, rax
    jnz     .loop
    ; special case: value is 0
    mov     byte [rbx], '0'
    lea     rax, [rbx]
    mov     rcx, 1
    jmp     .ret

.loop:
    test    rax, rax
    jz      .done_loop
    xor     rdx, rdx
    div     r12                 ; rax = quotient, rdx = remainder
    add     dl, '0'
    mov     byte [rbx], dl
    dec     rbx
    jmp     .loop

.done_loop:
    inc     rbx                 ; rbx now points to first digit
    ; compute length: end of buffer (cl_buf+23) minus start
    lea     rcx, [cl_buf + 23]
    sub     rcx, rbx
    mov     rax, rbx
.ret:
    pop     r12
    pop     rbx
    ret


; ============================================================
; http_respond_200_json
; Writes a complete HTTP 200 response with a JSON body.
;
; rdi = client fd
; rsi = json body pointer
; rdx = json body length (bytes)
; ============================================================
http_respond_200_json:
    push    rbx
    push    r12
    push    r13

    mov     rbx, rdi            ; fd
    mov     r12, rsi            ; json body ptr
    mov     r13, rdx            ; json body len

    ; write "HTTP/1.1 200 OK\r\nContent-Type: ...\r\nContent-Length: "
    mov     rdi, rbx
    mov     rsi, hdr_200
    mov     rdx, hdr_200_len
    call    write_all

    ; write decimal content-length
    mov     rdi, r13
    call    uint64_to_dec       ; rax=str ptr, rcx=len
    mov     rdi, rbx
    mov     rsi, rax
    mov     rdx, rcx
    call    write_all

    ; write \r\n\r\n
    mov     rdi, rbx
    mov     rsi, hdr_end
    mov     rdx, hdr_end_len
    call    write_all

    ; write body
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    call    write_all

    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================
; http_respond_404_json
; rdi = client fd
; ============================================================
http_respond_404_json:
    push    rbx
    mov     rbx, rdi

    ; header with content-length inline value
    mov     rdi, rbx
    mov     rsi, hdr_404
    mov     rdx, hdr_404_len
    call    write_all

    mov     rdi, body_404_len
    call    uint64_to_dec
    mov     rdi, rbx
    mov     rsi, rax
    mov     rdx, rcx
    call    write_all

    mov     rdi, rbx
    mov     rsi, hdr_end
    mov     rdx, hdr_end_len
    call    write_all

    mov     rdi, rbx
    mov     rsi, body_404
    mov     rdx, body_404_len
    call    write_all

    pop     rbx
    ret


; ============================================================
; http_respond_400_json
; rdi = client fd
; ============================================================
http_respond_400_json:
    push    rbx
    mov     rbx, rdi

    mov     rdi, rbx
    mov     rsi, hdr_400
    mov     rdx, hdr_400_len
    call    write_all

    mov     rdi, body_400_len
    call    uint64_to_dec
    mov     rdi, rbx
    mov     rsi, rax
    mov     rdx, rcx
    call    write_all

    mov     rdi, rbx
    mov     rsi, hdr_end
    mov     rdx, hdr_end_len
    call    write_all

    mov     rdi, rbx
    mov     rsi, body_400
    mov     rdx, body_400_len
    call    write_all

    pop     rbx
    ret
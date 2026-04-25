; ============================================================
; server.asm — tinydb TCP server
; ============================================================
; Build:  make server
; Run:    ./tinydb-server
; Test:   nc localhost 5000
;
; Protocol (newline-terminated plain text):
;   SET key value\n  →  OK\n
;   GET key\n        →  value\n  |  (nil)\n
;   DEL key\n        →  DEL 1\n  |  DEL 0\n
;
; sockaddr_in layout (16 bytes, big-endian fields):
;   +0  sin_family   2B  AF_INET = 2
;   +2  sin_port     2B  port in network byte order (big-endian)
;   +4  sin_addr     4B  INADDR_ANY = 0
;   +8  padding      8B  zeroed
;
; PORT 5000 in network byte order:
;   5000 = 0x1388  →  big-endian bytes: 0x13, 0x88
;   packed as word: 0x8813  (little-endian storage of big-endian value)

%include "include/constants.inc"
%include "include/network.inc"
%include "include/utils.inc"
%include "include/storage.inc"
%include "include/index.inc"

; ── bss: index record result buffer + value buffer ──────────
section .bss

cmd_buf:        resb CMD_BUF_SIZE   ; raw bytes from client
index_rec:      resb INDEX_RECORD_SIZE
val_buf:        resb MAX_VAL_LEN
optval:         resd 1              ; SO_REUSEADDR value (int)

; ── data: strings + sockaddr ────────────────────────────────
section .data

; sockaddr_in for bind — port 5000, INADDR_ANY
sockaddr:
    dw  AF_INET             ; sin_family = 2
    dw  0x8813              ; sin_port   = 5000 in network byte order
    dd  0                   ; sin_addr   = INADDR_ANY
    dq  0                   ; padding

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

str_SET:        db "SET", 0
str_GET:        db "GET", 0
str_DEL:        db "DEL", 0

; ── text ─────────────────────────────────────────────────────
section .text

global _start

; ── externs from existing modules ────────────────────────────
extern str_len
extern str_cmp
extern storage_append
extern storage_read
extern index_put
extern index_find
extern index_delete

; ============================================================
; _start
; ============================================================
_start:
    ; ── 1. socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) ─────────
    mov     rdi, AF_INET
    mov     rsi, SOCK_STREAM
    mov     rdx, IPPROTO_TCP
    call    net_socket
    cmp     rax, 0
    jl      .die
    mov     r12, rax            ; r12 = server fd

    ; ── 2. setsockopt(SO_REUSEADDR) ──────────────────────────
    ; Lets us restart the server immediately without waiting for
    ; the OS TIME_WAIT state to expire on the port.
    mov     dword [optval], 1
    mov     rdi, r12
    mov     rsi, SOL_SOCKET
    mov     rdx, SO_REUSEADDR
    lea     rcx, [optval]
    mov     r8,  4
    call    net_setsockopt

    ; ── 3. bind(server_fd, &sockaddr, 16) ────────────────────
    mov     rdi, r12
    lea     rsi, [sockaddr]
    mov     rdx, sockaddr_len
    call    net_bind
    cmp     rax, 0
    jl      .die

    ; ── 4. listen(server_fd, BACKLOG) ────────────────────────
    mov     rdi, r12
    mov     rsi, BACKLOG
    call    net_listen
    cmp     rax, 0
    jl      .die

; ── accept loop ──────────────────────────────────────────────
.accept_loop:
    ; accept(server_fd, NULL, NULL) → client_fd
    mov     rdi, r12
    xor     rsi, rsi
    xor     rdx, rdx
    call    net_accept
    cmp     rax, 0
    jl      .accept_loop        ; accept error — retry
    mov     r13, rax            ; r13 = client fd

; ── client read loop ─────────────────────────────────────────
; Read bytes into cmd_buf. Process one newline-terminated command
; per iteration. Remaining bytes after \n are discarded (single
; command per read — sufficient for interactive nc usage).
.client_loop:
    ; read(client_fd, cmd_buf, CMD_BUF_SIZE-1)
    mov     rdi, r13
    lea     rsi, [cmd_buf]
    mov     rdx, CMD_BUF_SIZE-1
    call    net_read
    cmp     rax, 1              ; 0=EOF, <0=error — both mean disconnect
    jl      .close_client

    mov     r14, rax            ; r14 = bytes received

    ; null-terminate buffer
    mov     byte [cmd_buf + r14], 0

    ; truncate at first \n so we process exactly one command
    ; even if the client sent multiple lines in one packet
    lea     rcx, [cmd_buf]
.find_nl:
    movzx   rax, byte [rcx]
    cmp     rax, 0
    je      .nl_done
    cmp     rax, 0x0A
    jne     .nl_next
    ; keep the \n so the strip logic below can find and remove it
    inc     rcx
    mov     byte [rcx], 0       ; null-terminate after \n
    jmp     .nl_done
.nl_next:
    inc     rcx
    jmp     .find_nl
.nl_done:

    ; ── parse: find and null-terminate first token (command) ──
    ; cmd_buf before:  "SET username jitendra\n"
    ; cmd_buf after:   "SET\0username\0jitendra\0"
    ;
    ; r15 = scan index

    xor     r15, r15            ; r15 = 0 (scan index)

    ; locate end of token 1 (command word)
    lea     rbx, [cmd_buf]      ; rbx = base of buffer

.find_sp1:
    movzx   rax, byte [rbx + r15]
    cmp     rax, 0
    je      .bad_cmd
    cmp     rax, ' '
    je      .split1
    inc     r15
    jmp     .find_sp1

.split1:
    mov     byte [rbx + r15], 0 ; null-terminate command token
    inc     r15
    mov     r8, r15             ; r8 = start of key token

    ; locate end of token 2 (key)
.find_sp2:
    movzx   rax, byte [rbx + r15]
    cmp     rax, 0
    je      .one_token_cmd      ; only one token after command — could be GET/DEL
    cmp     rax, ' '
    je      .split2
    cmp     rax, 0x0A           ; newline ends token too
    je      .one_token_cmd
    cmp     rax, 0x0D           ; carriage return
    je      .one_token_cmd
    inc     r15
    jmp     .find_sp2

.split2:
    mov     byte [rbx + r15], 0 ; null-terminate key token
    inc     r15
    mov     r9, r15             ; r9 = start of value token

    ; strip trailing \r\n from value token
    lea     rdi, [rbx + r9]
    call    str_len
    ; rax = value length
    cmp     rax, 0
    je      .have_three_tokens
    lea     rcx, [rbx + r9]     ; rcx = base of value token
    add     rcx, rax
    dec     rcx                  ; rcx → last byte
    movzx   rdx, byte [rcx]
    cmp     rdx, 0x0A
    jne     .check_cr
    mov     byte [rcx], 0
    dec     rcx
    dec     rax
.check_cr:
    cmp     rax, 0
    je      .have_three_tokens
    movzx   rdx, byte [rcx]
    cmp     rdx, 0x0D
    jne     .have_three_tokens
    mov     byte [rcx], 0

    jmp     .have_three_tokens

.one_token_cmd:
    ; strip \r\n from key token end
    lea     rdi, [rbx + r8]
    call    str_len
    cmp     rax, 0
    je      .dispatch_two
    lea     rcx, [rbx + r8]     ; rcx = base of key token
    add     rcx, rax
    dec     rcx                  ; rcx → last byte
    movzx   rdx, byte [rcx]
    cmp     rdx, 0x0A
    jne     .strip_cr2
    mov     byte [rcx], 0
    dec     rcx
    dec     rax
.strip_cr2:
    cmp     rax, 0
    je      .dispatch_two
    movzx   rdx, byte [rcx]
    cmp     rdx, 0x0D
    jne     .dispatch_two
    mov     byte [rcx], 0

.dispatch_two:
    ; tokens: [rbx]=cmd, [rbx+r8]=key — no value token
    lea     rdi, [rbx]
    lea     rsi, [str_GET]
    call    str_cmp
    test    rax, rax
    jz      .do_get

    lea     rdi, [rbx]
    lea     rsi, [str_DEL]
    call    str_cmp
    test    rax, rax
    jz      .do_del

    jmp     .bad_cmd

.have_three_tokens:
    ; tokens: [rbx]=cmd, [rbx+r8]=key, [rbx+r9]=value
    lea     rdi, [rbx]
    lea     rsi, [str_SET]
    call    str_cmp
    test    rax, rax
    jz      .do_set

    jmp     .bad_cmd

; ── SET ──────────────────────────────────────────────────────
.do_set:
    ; key = rbx+r8,  value = rbx+r9

    ; key length
    lea     rdi, [rbx + r8]
    call    str_len
    mov     r10, rax            ; r10 = key_len

    ; value length
    lea     rdi, [rbx + r9]
    call    str_len
    push    rax           ; r11 = val_len

    ; storage_append(value_ptr, val_len) → rax = data offset
    lea     rdi, [rbx + r9]
    mov     rsi, [rsp]
    call    storage_append
    cmp     rax, -1
    je      .send_err
    mov     rbp, rax            ; rbp = data offset

    ; index_put(key_ptr, key_len, data_offset, val_len)
    lea     rdi, [rbx + r8]
    mov     rsi, r10
    mov     rdx, rbp
    mov     rcx, [rsp]
    call    index_put
    cmp     rax, -1
    je      .send_err

    ; respond OK
    mov     rdi, r13
    lea     rsi, [resp_ok]
    mov     rdx, resp_ok_len
    call    net_write
    jmp     .client_loop

; ── GET ──────────────────────────────────────────────────────
.do_get:
    ; key = rbx+r8

    lea     rdi, [rbx + r8]
    call    str_len
    mov     r10, rax            ; r10 = key_len

    ; index_find(key_ptr, key_len, result_buf)
    lea     rdi, [rbx + r8]
    mov     rsi, r10
    lea     rdx, [index_rec]
    call    index_find
    cmp     rax, -1
    je      .send_nil

    ; extract offset and val_len from index record
    mov     rdi, [index_rec + INDEX_OFF_OFFSET]
    mov     esi, dword [index_rec + INDEX_OFF_VALLEN]
    lea     rdx, [val_buf]
    call    storage_read
    cmp     rax, -1
    je      .send_nil

    ; write value bytes
    mov     r10, rax            ; bytes read
    mov     rdi, r13
    lea     rsi, [val_buf]
    mov     rdx, r10
    call    net_write

    ; write trailing newline
    mov     rdi, r13
    lea     rsi, [resp_ok + 2]  ; points to the \n byte at end of resp_ok
    mov     rdx, 1
    call    net_write
    jmp     .client_loop

.send_nil:
    mov     rdi, r13
    lea     rsi, [resp_nil]
    mov     rdx, resp_nil_len
    call    net_write
    jmp     .client_loop

; ── DEL ──────────────────────────────────────────────────────
.do_del:
    ; key = rbx+r8

    lea     rdi, [rbx + r8]
    call    str_len
    mov     r10, rax

    ; index_delete(key_ptr, key_len)
    lea     rdi, [rbx + r8]
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

.bad_cmd:
.send_err:
    mov     rdi, r13
    lea     rsi, [resp_err]
    mov     rdx, resp_err_len
    call    net_write
    jmp     .client_loop

; ── close client, back to accept ─────────────────────────────
.close_client:
    mov     rdi, r13
    call    net_close
    jmp     .accept_loop

; ── fatal error — exit(1) ────────────────────────────────────
.die:
    mov     rdi, EXIT_ERR
    mov     rax, SYS_EXIT
    syscall
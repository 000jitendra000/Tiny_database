; ============================================================
; http_parser.asm — minimal HTTP/1.1 request parser
; ============================================================
; Parses only what tinydb needs:
;   - method (GET / POST)
;   - route (/get  /set  /del)
;   - query string key param  (?key=...)
;   - POST body fields        (key=...&value=...)
;
; All functions are non-destructive: they do not modify the
; request buffer. Results are written into caller-supplied
; output buffers and null-terminated.

%include "include/constants.inc"

%define HTTP_METHOD_GET     1
%define HTTP_METHOD_POST    2
%define HTTP_METHOD_UNKNOWN 0
%define HTTP_ROUTE_GET_KEY  1
%define HTTP_ROUTE_SET      2
%define HTTP_ROUTE_DEL      3
%define HTTP_ROUTE_UNKNOWN  0

section .data

str_GET_m:  db "GET ",  0       ; method token includes trailing space
str_POST_m: db "POST ", 0

str_route_get: db "/get",  0
str_route_set: db "/set",  0
str_route_del: db "/del",  0

str_key_eq:    db "key=",   0   ; query/body key param prefix
str_val_eq:    db "value=", 0   ; body value param prefix

str_crlfcrlf:  db 0x0D, 0x0A, 0x0D, 0x0A   ; \r\n\r\n header/body separator

section .text

global http_parse_method
global http_parse_route
global http_parse_query_key
global http_parse_post_key
global http_parse_post_value
global http_find_body

; ── internal helper: starts_with ─────────────────────────────
; rdi = haystack, rsi = needle (null-terminated)
; returns rax=1 if haystack starts with needle, else rax=0
; clobbers: rax, rcx, rdx — caller-saved so fine
starts_with:
.loop:
    movzx   rcx, byte [rsi]     ; needle byte
    test    rcx, rcx
    jz      .yes                ; reached end of needle → match
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


; ── internal helper: mem_find ────────────────────────────────
; Searches haystack[0..len) for first occurrence of needle (4 bytes).
; rdi = haystack ptr
; rsi = haystack length
; rdx = 4-byte needle value (as uint32)
; returns rax = pointer to match, or 0 if not found
mem_find4:
    mov     rcx, rsi
    sub     rcx, 3              ; last valid start = len-4
    jle     .not_found
    xor     r10, r10
.loop:
    cmp     r10, rcx
    jge     .not_found
    mov     eax, dword [rdi + r10]
    cmp     eax, edx
    je      .found
    inc     r10
    jmp     .loop
.found:
    lea     rax, [rdi + r10]
    ret
.not_found:
    xor     rax, rax
    ret


; ============================================================
; http_parse_method
; rdi = request buffer (null-terminated)
; returns rax = HTTP_METHOD_GET | HTTP_METHOD_POST | HTTP_METHOD_UNKNOWN
; ============================================================
http_parse_method:
    push    rdi
    mov     rsi, str_GET_m
    call    starts_with
    pop     rdi
    cmp     rax, 1
    je      .is_get

    push    rdi
    mov     rsi, str_POST_m
    call    starts_with
    pop     rdi
    cmp     rax, 1
    je      .is_post

    xor     rax, rax
    ret
.is_get:
    mov     rax, HTTP_METHOD_GET
    ret
.is_post:
    mov     rax, HTTP_METHOD_POST
    ret


; ============================================================
; http_parse_route
; rdi = request buffer (null-terminated)
; Finds the path token (second space-delimited token on line 1).
; returns rax = HTTP_ROUTE_GET_KEY | HTTP_ROUTE_SET | HTTP_ROUTE_DEL | HTTP_ROUTE_UNKNOWN
; ============================================================
http_parse_route:
    ; skip past the method word to the path
    ; e.g. "GET /get?key=x HTTP/1.1\r\n..."
    ;       ^^^^  skip 4 or 5 bytes to reach '/'
    ; Easiest: scan forward for first space, then skip space.
.skip_method:
    movzx   rax, byte [rdi]
    cmp     rax, 0
    je      .unknown
    cmp     rax, ' '
    je      .found_path_start
    inc     rdi
    jmp     .skip_method
.found_path_start:
    inc     rdi                 ; skip the space itself

    ; rdi now points to path, e.g. "/get?key=..."
    ; check /get
    push    rdi
    mov     rsi, str_route_get
    call    starts_with
    pop     rdi
    cmp     rax, 1
    je      .route_get

    push    rdi
    mov     rsi, str_route_set
    call    starts_with
    pop     rdi
    cmp     rax, 1
    je      .route_set

    push    rdi
    mov     rsi, str_route_del
    call    starts_with
    pop     rdi
    cmp     rax, 1
    je      .route_del

.unknown:
    xor     rax, rax
    ret
.route_get:
    mov     rax, HTTP_ROUTE_GET_KEY
    ret
.route_set:
    mov     rax, HTTP_ROUTE_SET
    ret
.route_del:
    mov     rax, HTTP_ROUTE_DEL
    ret


; ============================================================
; http_parse_query_key
; Extracts value of "key=" from the query string in the request line.
; e.g.  "GET /get?key=username HTTP/1.1"
;
; rdi = request buffer start
; rsi = output buffer for key (caller allocates MAX_KEY_LEN+1 bytes)
; returns rax = key length, 0 if not found
; ============================================================
http_parse_query_key:
    push    rbx
    push    r12
    push    r13

    mov     rbx, rdi            ; rbx = request buf
    mov     r12, rsi            ; r12 = output buffer

    ; scan for "key=" in the first line
    ; We scan byte by byte until \r, \n, or null — stopping at end of request line.
.scan:
    movzx   rax, byte [rbx]
    cmp     rax, 0
    je      .not_found
    cmp     rax, 0x0D           ; \r
    je      .not_found
    cmp     rax, 0x0A           ; \n
    je      .not_found

    ; check if "key=" starts here
    push    rbx
    mov     rdi, rbx
    mov     rsi, str_key_eq     ; "key="
    call    starts_with
    pop     rbx
    cmp     rax, 1
    je      .found_key

    inc     rbx
    jmp     .scan

.found_key:
    add     rbx, 4              ; skip "key="
    ; now copy until space, \r, \n, &, null
    xor     r13, r13            ; r13 = length counter
.copy:
    movzx   rax, byte [rbx]
    cmp     rax, 0
    je      .done
    cmp     rax, ' '
    je      .done
    cmp     rax, 0x0D
    je      .done
    cmp     rax, 0x0A
    je      .done
    cmp     rax, '&'
    je      .done
    cmp     r13, MAX_KEY_LEN
    jge     .done
    mov     byte [r12 + r13], al
    inc     r13
    inc     rbx
    jmp     .copy
.done:
    mov     byte [r12 + r13], 0 ; null-terminate
    mov     rax, r13
    jmp     .ret
.not_found:
    xor     rax, rax
.ret:
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================
; http_find_body
; Locates the body of an HTTP request (after \r\n\r\n).
;
; rdi = request buffer
; rsi = bytes read (length)
; returns rax = pointer to first body byte, or 0 if not found
; ============================================================
http_find_body:
    push    rbx
    push    r12

    mov     rbx, rdi
    mov     r12, rsi

    ; search for \r\n\r\n  (0x0D 0x0A 0x0D 0x0A)
    ; pack as little-endian uint32: 0x0A0D0A0D
    mov     rdi, rbx
    mov     rsi, r12
    mov     edx, 0x0A0D0A0D
    call    mem_find4
    test    rax, rax
    jz      .not_found

    add     rax, 4              ; skip past \r\n\r\n to body start
    jmp     .ret
.not_found:
    xor     rax, rax
.ret:
    pop     r12
    pop     rbx
    ret


; ============================================================
; http_parse_post_key
; Extracts "key=<value>" from POST body.
; e.g. body = "key=username&value=jitendra"
;
; rdi = body pointer
; rsi = output buffer
; returns rax = key length, 0 if not found
; ============================================================
http_parse_post_key:
    push    rbx
    push    r12
    push    r13

    mov     rbx, rdi
    mov     r12, rsi

    ; scan for "key=" in body
.scan:
    movzx   rax, byte [rbx]
    cmp     rax, 0
    je      .not_found

    push    rbx
    mov     rdi, rbx
    mov     rsi, str_key_eq
    call    starts_with
    pop     rbx
    cmp     rax, 1
    je      .found

    inc     rbx
    jmp     .scan

.found:
    add     rbx, 4              ; skip "key="
    xor     r13, r13
.copy:
    movzx   rax, byte [rbx]
    cmp     rax, 0
    je      .done
    cmp     rax, '&'
    je      .done
    cmp     rax, 0x0D
    je      .done
    cmp     rax, 0x0A
    je      .done
    cmp     r13, MAX_KEY_LEN
    jge     .done
    mov     byte [r12 + r13], al
    inc     r13
    inc     rbx
    jmp     .copy
.done:
    mov     byte [r12 + r13], 0
    mov     rax, r13
    jmp     .ret
.not_found:
    xor     rax, rax
.ret:
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================
; http_parse_post_value
; Extracts "value=<val>" from POST body.
; e.g. body = "key=username&value=jitendra"
;
; rdi = body pointer
; rsi = output buffer
; returns rax = value length, 0 if not found
; ============================================================
http_parse_post_value:
    push    rbx
    push    r12
    push    r13

    mov     rbx, rdi
    mov     r12, rsi

.scan:
    movzx   rax, byte [rbx]
    cmp     rax, 0
    je      .not_found

    push    rbx
    mov     rdi, rbx
    mov     rsi, str_val_eq     ; "value="
    call    starts_with
    pop     rbx
    cmp     rax, 1
    je      .found

    inc     rbx
    jmp     .scan

.found:
    add     rbx, 6              ; skip "value="
    xor     r13, r13
.copy:
    movzx   rax, byte [rbx]
    cmp     rax, 0
    je      .done
    cmp     rax, '&'
    je      .done
    cmp     rax, 0x0D
    je      .done
    cmp     rax, 0x0A
    je      .done
    cmp     r13, MAX_VAL_LEN - 1
    jge     .done
    mov     byte [r12 + r13], al
    inc     r13
    inc     rbx
    jmp     .copy
.done:
    mov     byte [r12 + r13], 0
    mov     rax, r13
    jmp     .ret
.not_found:
    xor     rax, rax
.ret:
    pop     r13
    pop     r12
    pop     rbx
    ret
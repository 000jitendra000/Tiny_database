; ============================================================
; utils.asm — string and I/O utility functions
; ============================================================
; These are the "stdlib" of our database. We implement them
; from scratch because we have no libc.
;
; Calling convention: Linux x86-64 System V ABI
;   args:    rdi, rsi, rdx, rcx, r8, r9
;   return:  rax
;   callee-saved: rbx, rbp, r12–r15 (we must preserve these)
;   caller-saved: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11

%include "include/constants.inc"

section .text

global str_len
global str_cmp
global print_str
global print_newline
global print_err

; ────────────────────────────────────────────────────────────
; str_len — compute the length of a null-terminated string
;
; Design: We walk byte-by-byte from rdi until we find 0x00.
; The count of bytes before the null is the length.
;
; Args:   rdi = pointer to null-terminated string
; Return: rax = length in bytes (not counting null terminator)
;
; Register usage:
;   rdi — pointer, advances through string
;   rax — length counter
;   al  — current byte being checked (low byte of rax)
; ────────────────────────────────────────────────────────────
str_len:
    xor     rax, rax            ; rax = 0 (our counter)
                                ; xor is faster than mov rax, 0
                                ; and also clears flags cleanly

.loop:
    cmp     byte [rdi + rax], 0 ; is byte at (rdi+rax) == null?
                                ; [rdi+rax] is "base+index" addressing
                                ; more efficient than incrementing rdi
    je      .done               ; yes → we found the end
    inc     rax                 ; no  → count this byte
    jmp     .loop

.done:
    ret                         ; rax holds the length


; ────────────────────────────────────────────────────────────
; str_cmp — compare two null-terminated strings
;
; Design: Walk both strings byte-by-byte. If any pair of bytes
; differs, strings are not equal. If both reach null together,
; they are equal.
;
; This is the same algorithm as libc strcmp(), just in assembly.
;
; Args:   rdi = pointer to string s1
;         rsi = pointer to string s2
; Return: rax = 0 if strings are equal
;         rax = 1 if strings differ
;
; Register usage:
;   rdi — pointer into s1
;   rsi — pointer into s2
;   al  — current byte from s1
;   cl  — current byte from s2
; ────────────────────────────────────────────────────────────
str_cmp:
    ; We use al and cl — both are low bytes of rax and rcx.
    ; We must be careful: after loading al, rax's upper bytes
    ; still have old values. We use movzx to zero-extend.

.loop:
    movzx   rax, byte [rdi]     ; rax = (zero-extended) *s1
    movzx   rcx, byte [rsi]     ; rcx = (zero-extended) *s2

    cmp     rax, rcx            ; are the bytes equal?
    jne     .not_equal          ; no → strings differ

    test    rax, rax            ; is s1's byte == 0?
                                ; (if both bytes equal AND s1==0, then s2==0 too)
    jz      .equal              ; yes → both strings ended together

    inc     rdi                 ; advance both pointers
    inc     rsi
    jmp     .loop

.equal:
    xor     rax, rax            ; return 0 (equal)
    ret

.not_equal:
    mov     rax, 1              ; return 1 (not equal)
    ret


; ────────────────────────────────────────────────────────────
; print_str — write a string to stdout
;
; Design: Direct SYS_WRITE syscall.
; The kernel writes exactly rsi bytes from the buffer at rdi.
;
; Args:   rdi = pointer to string data
;         rsi = number of bytes to write
; Return: rax = bytes written (from kernel)
;
; Syscall: write(fd=1, buf=rdi, count=rsi)
;   rax = 1 (SYS_WRITE)
;   rdi = 1 (STDOUT)
;   rsi = buffer pointer
;   rdx = byte count
;
; Note: The syscall clobbers rcx and r11 (kernel uses them
; for return address and flags). All other registers preserved.
; ────────────────────────────────────────────────────────────
print_str:
    ; We need to reorganize args for the syscall:
    ;   print_str args:   rdi=buf,  rsi=len
    ;   write syscall:    rdi=fd,   rsi=buf,  rdx=count
    ;
    ; The shift:
    ;   rdx ← rsi  (len becomes count)
    ;   rsi ← rdi  (buf pointer shifts to rsi)
    ;   rdi ← 1    (fd = stdout)

    mov     rdx, rsi            ; rdx = length
    mov     rsi, rdi            ; rsi = buffer pointer
    mov     rdi, STDOUT         ; rdi = 1 (stdout fd)
    mov     rax, SYS_WRITE      ; rax = 1
    syscall
    ret


; ────────────────────────────────────────────────────────────
; print_newline — write a single newline to stdout
;
; We store the newline byte in the .data section and write 1 byte.
; ────────────────────────────────────────────────────────────
print_newline:
    mov     rdi, STDOUT
    mov     rsi, newline_char   ; pointer to the '\n' byte
    mov     rdx, 1
    mov     rax, SYS_WRITE
    syscall
    ret


; ────────────────────────────────────────────────────────────
; print_err — write a string to stderr
;
; Same as print_str but fd=2.
; Used for error messages that should not mix with stdout output.
;
; Args:   rdi = pointer to string
;         rsi = length
; ────────────────────────────────────────────────────────────
print_err:
    mov     rdx, rsi
    mov     rsi, rdi
    mov     rdi, STDERR
    mov     rax, SYS_WRITE
    syscall
    ret


; ────────────────────────────────────────────────────────────
section .data

newline_char: db 0x0A           ; ASCII 10 = '\n'
; ============================================================
; network.asm — Linux socket syscall wrappers
; ============================================================

%include "include/constants.inc"

; network syscall numbers
%define SYS_SOCKET    41
%define SYS_BIND      49
%define SYS_LISTEN    50
%define SYS_ACCEPT    43
%define SYS_SETSOCKOPT 54

section .text

global net_socket
global net_bind
global net_listen
global net_accept
global net_read
global net_write
global net_close
global net_setsockopt

; net_socket(domain, type, protocol) → rax=fd or -1
net_socket:
    mov     rax, SYS_SOCKET
    syscall
    ret

; net_bind(fd, sockaddr_ptr, addrlen) → rax=0 or -1
net_bind:
    mov     rax, SYS_BIND
    syscall
    ret

; net_listen(fd, backlog) → rax=0 or -1
net_listen:
    mov     rax, SYS_LISTEN
    syscall
    ret

; net_accept(fd, 0, 0) → rax=client_fd or -1
net_accept:
    mov     rax, SYS_ACCEPT
    syscall
    ret

; net_read(fd, buf, count) → rax=bytes or -1
net_read:
    mov     rax, SYS_READ
    syscall
    ret

; net_write(fd, buf, count) → rax=bytes or -1
net_write:
    mov     rax, SYS_WRITE
    syscall
    ret

; net_close(fd) → void
net_close:
    mov     rax, SYS_CLOSE
    syscall
    ret

; net_setsockopt(fd, level, optname, optval_ptr, optlen) → rax=0 or -1
net_setsockopt:
    mov     rax, SYS_SETSOCKOPT
    syscall
    ret
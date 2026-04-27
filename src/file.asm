; ============================================================
; file.asm — thin syscall wrappers for file I/O
; ============================================================
; These functions are 1:1 wrappers around Linux syscalls.
; They exist so the rest of our code never writes raw syscall
; numbers — everything goes through named functions.
;
; This is the same pattern used by libc's open(), read(), etc.
; We just skip the errno plumbing.

%include "include/constants.inc"

section .text

global file_open
global file_close
global file_read
global file_write
global file_seek


; ────────────────────────────────────────────────────────────
; file_open — open or create a file
;
; Syscall: open(pathname, flags, mode)
;   rax = SYS_OPEN (2)
;   rdi = pathname (null-terminated string)
;   rsi = flags    (O_RDWR | O_CREAT | O_APPEND etc.)
;   rdx = mode     (e.g. 0o644, used only when O_CREAT is set)
;
; Args match the syscall exactly — no register shuffling needed.
;
; Return: rax = file descriptor (positive integer)
;         rax = negative errno on error (e.g. -2 = ENOENT)
;
; Key insight about flags:
;   When the kernel opens a file with O_APPEND, every write()
;   atomically seeks to EOF first. This is crucial for our
;   append-only data.db — it means two processes can't corrupt
;   each other's writes (mostly — on local fs it's atomic).
; ────────────────────────────────────────────────────────────
file_open:
    ; openat(AT_FDCWD, pathname, flags, mode)

    mov     r10, rdx        ; mode -> r10 (4th arg)
    mov     rdx, rsi        ; flags -> rdx (3rd arg)
    mov     rsi, rdi        ; pathname -> rsi (2nd arg)
    mov     rdi, -100       ; AT_FDCWD (1st arg)

    mov     rax, SYS_OPENAT
    syscall
    ret

; ────────────────────────────────────────────────────────────
; file_close — close a file descriptor
;
; Syscall: close(fd)
;   rax = SYS_CLOSE (3)
;   rdi = fd
;
; Important: Always close fds you open. File descriptors are a
; finite kernel resource. A process can only have ~1024 open
; at once (soft limit). Leaking them = eventual EMFILE error.
; ────────────────────────────────────────────────────────────
file_close:
    mov     rax, SYS_CLOSE
    syscall
    ret


; ────────────────────────────────────────────────────────────
; file_read — read bytes from a file descriptor
;
; Syscall: read(fd, buf, count)
;   rax = SYS_READ (0)
;   rdi = fd
;   rsi = buffer pointer
;   rdx = max bytes to read
;
; Return: rax = bytes actually read
;         rax = 0  → end of file (no more data)
;         rax < 0  → error
;
; Critical: read() may return LESS than count bytes.
; This is not an error — it's called a "short read."
; In production code you loop until you get all bytes.
; Our current engine always reads exactly what we need,
; but be aware of this in any future extension.
; ────────────────────────────────────────────────────────────
file_read:
    mov     rax, SYS_READ
    syscall
    ret


; ────────────────────────────────────────────────────────────
; file_write — write bytes to a file descriptor
;
; Syscall: write(fd, buf, count)
;   rax = SYS_WRITE (1)
;   rdi = fd
;   rsi = buffer pointer
;   rdx = number of bytes to write
;
; Return: rax = bytes actually written
;         rax < 0 → error
;
; Same caveat as read: "short writes" can happen on pipes,
; sockets, or when signals interrupt the call. On regular
; files with O_APPEND, writes are typically complete.
; ────────────────────────────────────────────────────────────
file_write:
    mov     rax, SYS_WRITE
    syscall
    ret


; ────────────────────────────────────────────────────────────
; file_seek — reposition file offset
;
; Syscall: lseek(fd, offset, whence)
;   rax = SYS_LSEEK (8)
;   rdi = fd
;   rsi = offset (signed 64-bit integer)
;   rdx = whence: SEEK_SET=0, SEEK_CUR=1, SEEK_END=2
;
; Return: rax = new absolute byte offset from file start
;         rax < 0 → error
;
; The three whence values let you:
;   SEEK_SET 0: go to exact byte position  (lseek fd, 100, 0)
;   SEEK_CUR 1: go forward/back N bytes    (lseek fd,  +5, 1)
;   SEEK_END 2: go relative to EOF         (lseek fd,   0, 2) = end of file
;
; This is how GET works:
;   1. lseek(data_fd, stored_offset, SEEK_SET) → position cursor
;   2. read(data_fd, buf, val_len)             → read exact bytes
;
; And how we get the current write offset for SET:
;   lseek(data_fd, 0, SEEK_END) → returns current file size
;   This is the offset where our next append will land.
; ────────────────────────────────────────────────────────────
file_seek:
    mov     rax, SYS_LSEEK
    syscall
    ret
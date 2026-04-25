; syscall numbers
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_LSEEK       8
%define SYS_EXIT        60

; file flags
%define O_RDONLY        0
%define O_RDWR          2
%define O_CREAT         64
%define O_APPEND        1024

; seek constants
%define SEEK_SET        0
%define SEEK_CUR        1
%define SEEK_END        2

; std fds
%define STDOUT          1
%define STDERR          2

; exit codes
%define EXIT_OK         0
%define EXIT_ERR        1

; file permissions
%define MODE_FILE       0644o

; database constants
%define INDEX_RECORD_SIZE   80
%define MAX_KEY_LEN         63
%define MAX_VAL_LEN         1024

; index layout offsets
%define INDEX_OFF_KEYLEN    0
%define INDEX_OFF_KEY       1
%define INDEX_OFF_OFFSET    64
%define INDEX_OFF_VALLEN    72
%define INDEX_OFF_DELETED   76
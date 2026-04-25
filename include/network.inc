extern net_socket
extern net_bind
extern net_listen
extern net_accept
extern net_read
extern net_write
extern net_close
extern net_setsockopt

; socket constants
%define AF_INET         2
%define SOCK_STREAM     1
%define IPPROTO_TCP     6

; socket options
%define SOL_SOCKET      1
%define SO_REUSEADDR    2

; server config
%define BACKLOG         10
%define CMD_BUF_SIZE    1024
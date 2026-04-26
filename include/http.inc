; ============================================================
; http.inc — HTTP constants + extern declarations
; ============================================================

; ── HTTP methods ────────────────────────────────────────────
%define HTTP_METHOD_UNKNOWN     0
%define HTTP_METHOD_GET         1
%define HTTP_METHOD_POST        2

; ── Routes ──────────────────────────────────────────────────
%define HTTP_ROUTE_UNKNOWN      0
%define HTTP_ROUTE_GET_KEY      1
%define HTTP_ROUTE_SET          2
%define HTTP_ROUTE_DEL          3

; ── Server config ───────────────────────────────────────────
%define HTTP_PORT               8080

; 8080 in network byte order (big-endian)
; decimal 8080 = 0x1F90
; stored in sockaddr as bytes 1F 90
; on little-endian x86 that means the word literal is 0x901F
%define HTTP_PORT_NBO           0x901F

; request/response buffers
%define HTTP_BUF_SIZE           4096
%define HTTP_VAL_BUF            2048

; ── Parser exports ──────────────────────────────────────────
extern http_parse_method
extern http_parse_route
extern http_parse_query_key
extern http_parse_post_key
extern http_parse_post_value
extern http_find_body

; ── Response exports ────────────────────────────────────────
extern http_respond_200_json
extern http_respond_404_json
extern http_respond_400_json
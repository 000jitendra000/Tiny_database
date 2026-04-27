; ============================================================
; schema.inc — schema layer constants + externs
; ============================================================

; limits (must match schema.asm)
%define MAX_SCHEMA_FIELDS    16
%define MAX_FIELD_NAME_LEN   32
%define MAX_RECORD_VAL_LEN   1024

; ── schema functions ─────────────────────────────────────────
extern schema_init
extern schema_load
extern schema_serialize
extern schema_print_record
extern schema_format_json
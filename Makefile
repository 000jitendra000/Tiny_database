# ============================================================
# Makefile — tinydb build system
# ============================================================
# NASM produces .o (ELF64 object) files.
# ld links them into a static executable.
# No libc. No runtime. Pure syscalls.

NASM    := nasm
LD      := ld
NASMFLAGS := -f elf64 -I ./  # -f elf64: output format
                               # -I ./: include search path (for %include)
LDFLAGS  :=                    # no special linker flags needed

SRC_DIR  := src
BUILD_DIR := build
BIN      := tinydb
SERVER   := tinydb-server

# All assembly source files
SRCS := $(SRC_DIR)/main.asm     \
        $(SRC_DIR)/utils.asm    \
        $(SRC_DIR)/file.asm     \
        $(SRC_DIR)/storage.asm  \
        $(SRC_DIR)/index.asm

SERVER_SRCS := $(SRC_DIR)/server.asm   \
               $(SRC_DIR)/network.asm  \
               $(SRC_DIR)/utils.asm    \
               $(SRC_DIR)/file.asm     \
               $(SRC_DIR)/storage.asm  \
               $(SRC_DIR)/index.asm

# Object files: src/foo.asm → build/foo.o
OBJS        := $(patsubst $(SRC_DIR)/%.asm, $(BUILD_DIR)/%.o, $(SRCS))
SERVER_OBJS := $(patsubst $(SRC_DIR)/%.asm, $(BUILD_DIR)/%.o, $(SERVER_SRCS))

.PHONY: all server clean run-set run-get run-del dirs

all: dirs $(BIN)
server: dirs $(SERVER)

# Create build and db directories if they don't exist
dirs:
	mkdir -p $(BUILD_DIR) db

# Link all object files into the final executable
$(BIN): $(OBJS)
	$(LD) $(LDFLAGS) -o $@ $^
	@echo "Built: $(BIN)"

$(SERVER): $(SERVER_OBJS)
	$(LD) $(LDFLAGS) -o $@ $^
	@echo "Built: $(SERVER)"

# Assemble each .asm → .o
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.asm
	$(NASM) $(NASMFLAGS) -o $@ $<

# ── Convenience targets ──────────────────────────────────────
run-set:
	./$(BIN) SET username jitendra

run-get:
	./$(BIN) GET username

run-del:
	./$(BIN) DEL username

# Wipe the database files (fresh start)
clean-db:
	rm -f db/index.db db/data.db

# Full clean
clean:
	rm -f $(BUILD_DIR)/*.o $(BIN) $(SERVER)
	@echo "Cleaned."

# Show hex dump of database files (useful for debugging)
inspect:
	@echo "=== index.db ==="
	@xxd db/index.db 2>/dev/null || echo "(empty)"
	@echo ""
	@echo "=== data.db ==="
	@xxd db/data.db 2>/dev/null || echo "(empty)"
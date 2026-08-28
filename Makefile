# Command-line build (Xcode uses OTHER_AFLAGS -I$(SRCROOT) for the same incbin).
CC     ?= clang
CFLAGS ?= -arch arm64
TARGET  = build/16ForthCLI
SRC     = 16ForthCLI/kernel.s 16ForthCLI/host_io.c

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SRC) 16ForthCLI/kernel.fth
	mkdir -p build
	$(CC) $(CFLAGS) -o $@ $(SRC) -I .

clean:
	rm -rf build

test:
	./tests/run.sh

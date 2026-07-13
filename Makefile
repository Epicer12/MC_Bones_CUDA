# CPU brute finder for Colab / Linux (no GPU required).
# Usage: bash setup_colab.sh && make && make run

CC ?= gcc
CXXFLAGS ?= -O3
CUBIOMES ?= cubiomes
CUBIOMES_BUILD ?= $(CUBIOMES)/build-loot56
CUBIOMES_LIB ?= $(CUBIOMES_BUILD)/libcubiomes_static.a

.PHONY: all clean run desert_pyramid_brute

all: desert_pyramid_brute

desert_pyramid_brute: desert_pyramid_brute.c $(CUBIOMES_LIB)
	$(CC) $(CXXFLAGS) -fwrapv -Wall -Wextra -I"$(CUBIOMES)" -o $@ desert_pyramid_brute.c "$(CUBIOMES_LIB)" -lm -pthread

$(CUBIOMES_LIB):
	@test -f "$(CUBIOMES)/finders.h" || { \
		echo "ERROR: cubiomes not found at $(CUBIOMES)"; \
		echo "  Colab: bash setup_colab.sh   (auto-clones cubiomes)"; \
		exit 1; \
	}
	mkdir -p "$(CUBIOMES_BUILD)"
	cd "$(CUBIOMES_BUILD)" && cmake .. -DCMAKE_BUILD_TYPE=Release && cmake --build . --target cubiomes_static

clean:
	rm -f desert_pyramid_brute

run: desert_pyramid_brute
	./desert_pyramid_brute --struct-range 100000000 10000000000 \
		--exact 56 --regions 4 --sisters 65536 \
		--threads $$(nproc) --out brute_out.txt --progress-out brute_progress.txt

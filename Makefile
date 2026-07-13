# Standalone build for Colab T4 (sm_75) or other NVIDIA GPUs.
# Usage: bash setup_colab.sh && make run-struct
#        make NVCC=/usr/local/cuda/bin/nvcc

NVCC ?= nvcc
CC ?= gcc
ARCH ?= sm_75
CXXFLAGS ?= -O3
CUBIOMES ?= cubiomes
CUBIOMES_BUILD ?= $(CUBIOMES)/build-loot56
CUBIOMES_LIB ?= $(CUBIOMES_BUILD)/libcubiomes_static.a

.PHONY: all clean run-small run-t4 run-link run-struct check-nvcc cubiomes-lib

all: check-nvcc loot56_cuda link56_cuda struct56_cuda

check-nvcc:
	@command -v $(NVCC) >/dev/null 2>&1 || { \
		echo "ERROR: $(NVCC) not found."; \
		echo "  Colab: bash setup_colab.sh   then   make"; \
		echo "  Or:    make NVCC=/usr/local/cuda/bin/nvcc"; \
		exit 127; \
	}

$(CUBIOMES_LIB):
	@test -f "$(CUBIOMES)/finders.h" || { \
		echo "ERROR: cubiomes not found at $(CUBIOMES)"; \
		echo "  Colab: bash setup_colab.sh   (auto-clones cubiomes)"; \
		exit 1; \
	}
	mkdir -p "$(CUBIOMES_BUILD)"
	cd "$(CUBIOMES_BUILD)" && cmake .. -DCMAKE_BUILD_TYPE=Release && cmake --build . --target cubiomes_static

struct56_verify.o: struct56_verify.c struct56_verify.h
	$(CC) $(CXXFLAGS) -I"$(CUBIOMES)" -c -o $@ struct56_verify.c

loot56_cuda: loot56_cuda.cu
	$(NVCC) $(CXXFLAGS) -arch=$(ARCH) -o $@ $<

link56_cuda: link56_cuda.cu link56_rng.cuh
	$(NVCC) $(CXXFLAGS) -arch=$(ARCH) -o $@ link56_cuda.cu

struct56_cuda: struct56_cuda.cu link56_rng.cuh struct56_verify.o struct56_verify.h $(CUBIOMES_LIB)
	$(NVCC) $(CXXFLAGS) -arch=$(ARCH) -I"$(CUBIOMES)" -o $@ struct56_cuda.cu struct56_verify.o "$(CUBIOMES_LIB)" -lm

clean:
	rm -f loot56_cuda link56_cuda struct56_cuda struct56_verify.o
	rm -f loot56_cuda_hits.txt link56_hits.txt struct56_hits.txt struct56_mitm.txt

run-small: loot56_cuda
	./loot56_cuda --loot-range 0 50000000000 --out loot56_hits.txt

run-t4: loot56_cuda
	./loot56_cuda --loot-range 0 50000000000 --out loot56_hits.txt \
		--grid-size 16384 --seeds-per-thread 128

run-link: link56_cuda
	./link56_cuda --loot-file loot56_hits.txt \
		--struct-range 20000000000 80000000000 \
		--region-grid 100 --out link56_hits.txt \
		--grid-size 16384 --batch-struct-seeds 50000

run-struct: struct56_cuda
	./struct56_cuda --struct-range 160000000000 281474976710656 \
		--region 0 0 --mitm \
		--out struct56_hits.txt --mitm-out struct56_mitm.txt \
		--grid-size 16384 --seeds-per-thread 128

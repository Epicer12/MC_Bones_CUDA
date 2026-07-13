# Standalone build for Colab T4 (sm_75) or other NVIDIA GPUs.
# Usage: bash setup_colab.sh && make run-t4
#        make NVCC=/usr/local/cuda/bin/nvcc

NVCC ?= nvcc
ARCH ?= sm_75
CXXFLAGS ?= -O3

.PHONY: all clean run-small run-t4 run-link check-nvcc

all: check-nvcc loot56_cuda link56_cuda

check-nvcc:
	@command -v $(NVCC) >/dev/null 2>&1 || { \
		echo "ERROR: $(NVCC) not found."; \
		echo "  Colab: bash setup_colab.sh   then   make"; \
		echo "  Or:    make NVCC=/usr/local/cuda/bin/nvcc"; \
		exit 127; \
	}

loot56_cuda: loot56_cuda.cu
	$(NVCC) $(CXXFLAGS) -arch=$(ARCH) -o $@ $<

link56_cuda: link56_cuda.cu link56_rng.cuh
	$(NVCC) $(CXXFLAGS) -arch=$(ARCH) -o $@ link56_cuda.cu

clean:
	rm -f loot56_cuda link56_cuda loot56_cuda_hits.txt link56_hits.txt

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

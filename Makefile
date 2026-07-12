# Standalone build for Colab T4 (sm_75) or other NVIDIA GPUs.
# Usage: make [ARCH=sm_75] [run-t4]

NVCC ?= nvcc
ARCH ?= sm_75
CXXFLAGS ?= -O3

.PHONY: all clean run-small run-t4

all: loot56_cuda

loot56_cuda: loot56_cuda.cu
	$(NVCC) $(CXXFLAGS) -arch=$(ARCH) -o $@ $<

clean:
	rm -f loot56_cuda loot56_hits.txt loot56_cuda_hits.txt

run-small: loot56_cuda
	./loot56_cuda --loot-range 0 50000000000 --out loot56_hits.txt

run-t4: loot56_cuda
	./loot56_cuda --loot-range 0 50000000000 --out loot56_hits.txt \
		--grid-size 16384 --seeds-per-thread 128

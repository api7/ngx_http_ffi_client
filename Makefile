.PHONY: bench test

bench:
	@./benchmark/run.sh

test:
	@prove -r t

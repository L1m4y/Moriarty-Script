.PHONY: check lint test format

check: lint test

lint:
	bash -n moriarty.sh
	bash -n moriarty-restore.sh
	bash -n tests/run.sh
	shellcheck -x moriarty.sh moriarty-restore.sh tests/run.sh
	shfmt -d -i 2 -ci moriarty.sh moriarty-restore.sh tests/run.sh

test:
	bash tests/run.sh

format:
	shfmt -w -i 2 -ci moriarty.sh moriarty-restore.sh tests/run.sh

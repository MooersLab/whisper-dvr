# Makefile for whisper-dvr.el
# Run ERT tests and perform byte compilation checks

EMACS ?= emacs
BATCH = $(EMACS) --batch -Q

# Source files
SRC = whisper-dvr.el
TEST = whisper-dvr-test.el

# Byte-compiled files
ELC = $(SRC:.el=.elc)
TEST_ELC = $(TEST:.el=.elc)

# Load path for dependencies
LOAD_PATH = -L .

# Mock whisper.el for testing (provides minimal stubs)
MOCK_WHISPER = --eval "(provide 'whisper)" \
               --eval "(defun whisper-file (file) nil)"

.PHONY: all test test-unit test-integration test-verbose \
        compile lint clean help ci

all: compile test

test:
	@echo "Running all tests..."
	$(BATCH) $(LOAD_PATH) \
		$(MOCK_WHISPER) \
		-l ert \
		-l $(SRC) \
		-l $(TEST) \
		-f ert-run-tests-batch-and-exit

test-unit:
	@echo "Running unit tests..."
	$(BATCH) $(LOAD_PATH) \
		$(MOCK_WHISPER) \
		-l ert \
		-l $(SRC) \
		-l $(TEST) \
		--eval '(ert-run-tests-batch-and-exit "^whisper-dvr-test-[^i]")'

test-integration:
	@echo "Running integration tests..."
	$(BATCH) $(LOAD_PATH) \
		$(MOCK_WHISPER) \
		-l ert \
		-l $(SRC) \
		-l $(TEST) \
		--eval '(ert-run-tests-batch-and-exit "whisper-dvr-test-integration")'

test-edge:
	@echo "Running edge case tests..."
	$(BATCH) $(LOAD_PATH) \
		$(MOCK_WHISPER) \
		-l ert \
		-l $(SRC) \
		-l $(TEST) \
		--eval '(ert-run-tests-batch-and-exit "whisper-dvr-test-edge")'

test-verbose:
	@echo "Running all tests (verbose)..."
	$(BATCH) $(LOAD_PATH) \
		$(MOCK_WHISPER) \
		-l ert \
		-l $(SRC) \
		-l $(TEST) \
		--eval '(setq ert-batch-print-level 10)' \
		--eval '(setq ert-batch-print-length 15)' \
		-f ert-run-tests-batch-and-exit

test-one:
	@echo "Running test: $(TEST_NAME)"
	$(BATCH) $(LOAD_PATH) \
		$(MOCK_WHISPER) \
		-l ert \
		-l $(SRC) \
		-l $(TEST) \
		--eval '(ert-run-tests-batch-and-exit "$(TEST_NAME)")'

compile: $(ELC)
	@echo "Byte compilation complete."

$(ELC): $(SRC)
	@echo "Byte-compiling $<..."
	$(BATCH) $(LOAD_PATH) \
		$(MOCK_WHISPER) \
		--eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile $<

compile-test: $(TEST_ELC)
	@echo "Test byte compilation complete."

$(TEST_ELC): $(TEST) $(SRC)
	@echo "Byte-compiling $<..."
	$(BATCH) $(LOAD_PATH) \
		$(MOCK_WHISPER) \
		-l $(SRC) \
		-f batch-byte-compile $<

lint:
	@echo "Running lint checks..."
	$(BATCH) $(LOAD_PATH) \
		$(MOCK_WHISPER) \
		--eval '(setq byte-compile-error-on-warn t)' \
		-l $(SRC) \
		--eval '(checkdoc-file "$(SRC)")' \
		-f batch-byte-compile $(SRC)
	@echo "Lint checks passed."

checkdoc:
	@echo "Running checkdoc..."
	$(BATCH) $(LOAD_PATH) \
		$(MOCK_WHISPER) \
		-l $(SRC) \
		--eval '(checkdoc-file "$(SRC)")'

ci: compile lint test
	@echo "All CI checks passed."

clean:
	@echo "Cleaning up..."
	rm -f $(ELC) $(TEST_ELC)
	rm -f *~
	rm -f \#*\#

list-tests:
	@echo "Available tests:"
	@$(BATCH) $(LOAD_PATH) \
		$(MOCK_WHISPER) \
		-l ert \
		-l $(SRC) \
		-l $(TEST) \
		--eval '(mapatoms (lambda (s) (when (and (ert-test-boundp s) (string-prefix-p "whisper-dvr-test" (symbol-name s))) (princ (format "  %s\n" s)))))'

help:
	@echo "whisper-dvr.el Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all              Compile and test (default)"
	@echo "  test             Run all tests"
	@echo "  test-unit        Run unit tests only"
	@echo "  test-integration Run integration tests only"
	@echo "  test-edge        Run edge case tests only"
	@echo "  test-verbose     Run tests with verbose output"
	@echo "  test-one         Run single test (TEST_NAME=name)"
	@echo "  compile          Byte-compile source files"
	@echo "  lint             Run checkdoc and compile checks"
	@echo "  ci               Run full CI suite"
	@echo "  clean            Remove generated files"
	@echo "  list-tests       List all available tests"
	@echo "  help             Show this message"

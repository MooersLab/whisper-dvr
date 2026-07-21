# Makefile for whisper-dvr.el
# Author: Blaine Mooers
# 
# This Makefile provides targets for testing, linting, and packaging
# the whisper-dvr Emacs package.

EMACS ?= emacs
BATCH = $(EMACS) --batch -Q

# Source files
SRCS = whisper-dvr.el
TESTS = whisper-dvr-test.el
TEXI = whisper-dvr.texi

# Package information
PACKAGE_NAME = whisper-dvr
VERSION = $(shell grep -E "^;; Version:" whisper-dvr.el | sed 's/;; Version: //')

# Documentation tools
MAKEINFO ?= makeinfo
TEXI2PDF ?= texi2pdf

.PHONY: all test test-verbose lint compile clean help install-deps info pdf html docs

all: compile test lint

## Help target
help:
	@echo "whisper-dvr Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all           Run compile, test, and lint (default)"
	@echo "  test          Run ERT tests"
	@echo "  test-verbose  Run ERT tests with verbose output"
	@echo "  lint          Run package-lint and checkdoc"
	@echo "  compile       Byte-compile the source files"
	@echo "  clean         Remove compiled files"
	@echo "  install-deps  Install development dependencies"
	@echo "  info          Generate Info documentation"
	@echo "  pdf           Generate PDF documentation"
	@echo "  html          Generate HTML documentation"
	@echo "  docs          Generate all documentation formats"
	@echo "  help          Show this help message"

## Install development dependencies
install-deps:
	$(BATCH) --eval "(progn \
	  (require 'package) \
	  (add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t) \
	  (package-initialize) \
	  (package-refresh-contents) \
	  (package-install 'package-lint))"

## Run tests
test:
	@echo "Running tests..."
	$(BATCH) \
	  --eval "(add-to-list 'load-path \".\")" \
	  --eval "(setq whisper-install-whispercpp nil)" \
	  --eval "(provide 'whisper)" \
	  --eval "(defun whisper-run (&optional _arg) nil)" \
	  -l ert \
	  -l $(SRCS) \
	  -l $(TESTS) \
	  -f ert-run-tests-batch-and-exit

## Run tests with verbose output
test-verbose:
	@echo "Running tests (verbose)..."
	$(BATCH) \
	  --eval "(add-to-list 'load-path \".\")" \
	  --eval "(setq whisper-install-whispercpp nil)" \
	  --eval "(provide 'whisper)" \
	  --eval "(defun whisper-run (&optional _arg) nil)" \
	  -l ert \
	  -l $(SRCS) \
	  -l $(TESTS) \
	  --eval "(ert-run-tests-batch-and-exit t)"

## Lint the source files
lint: lint-checkdoc lint-package

lint-checkdoc:
	@echo "Running checkdoc..."
	$(BATCH) \
	  --eval "(require 'checkdoc)" \
	  --eval "(setq sentence-end-double-space nil)" \
	  --eval "(checkdoc-file \"$(SRCS)\")"

lint-package:
	@echo "Running package-lint..."
	$(BATCH) \
	  --eval "(require 'package)" \
	  --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
	  --eval "(package-initialize)" \
	  --eval "(unless (package-installed-p 'package-lint) \
	            (package-refresh-contents) \
	            (package-install 'package-lint))" \
	  --eval "(require 'package-lint)" \
	  -f package-lint-batch-and-exit $(SRCS)

## Byte-compile the source files
compile:
	@echo "Byte-compiling..."
	$(BATCH) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  --eval "(add-to-list 'load-path \".\")" \
	  --eval "(setq whisper-install-whispercpp nil)" \
	  --eval "(provide 'whisper)" \
	  --eval "(defun whisper-run (&optional _arg) nil)" \
	  -f batch-byte-compile $(SRCS)

## Clean compiled files
clean:
	@echo "Cleaning..."
	rm -f *.elc
	rm -f *~
	rm -f \#*\#
	rm -f *.aux *.cp *.cps *.fn *.fns *.ky *.log *.pg *.toc *.tp *.vr *.vrs

## Generate Info documentation
info: $(TEXI)
	@echo "Generating Info documentation..."
	$(MAKEINFO) $(TEXI)

## Generate PDF documentation
pdf: $(TEXI)
	@echo "Generating PDF documentation..."
	$(TEXI2PDF) $(TEXI)

## Generate HTML documentation
html: $(TEXI)
	@echo "Generating HTML documentation..."
	$(MAKEINFO) --html --no-split $(TEXI)

## Generate all documentation formats
docs: info pdf html
	@echo "All documentation generated."

## Run a single test (usage: make test-single TEST=test-name)
test-single:
	@echo "Running single test: $(TEST)"
	$(BATCH) \
	  --eval "(add-to-list 'load-path \".\")" \
	  --eval "(setq whisper-install-whispercpp nil)" \
	  --eval "(provide 'whisper)" \
	  --eval "(defun whisper-run (&optional _arg) nil)" \
	  -l ert \
	  -l $(SRCS) \
	  -l $(TESTS) \
	  --eval "(ert-run-tests-batch-and-exit '$(TEST))"

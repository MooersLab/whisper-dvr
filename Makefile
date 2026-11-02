# Makefile for whisper-dvr.el
# Author: Blaine Mooers
#
# This Makefile provides targets for testing, linting, and packaging
# the whisper-dvr Emacs package.

EMACS ?= emacs
BATCH = $(EMACS) --batch -Q

# Source files.  The replacements library is listed first because
# whisper-dvr.el requires it.
SRCS = whisper-dvr-replacements.el whisper-dvr.el
TESTS = whisper-dvr-test.el whisper-dvr-replacements-test.el
TEXI = whisper-dvr.texi
LOAD_SRCS = $(addprefix -l ,$(SRCS))
LOAD_TESTS = $(addprefix -l ,$(TESTS))

# Claude skill with the Python twin of the replacement engine
SKILL = voice-in-replacements
SKILL_DIR = skills/$(SKILL)
SKILL_DATA = $(SKILL_DIR)/data
PYTHON ?= python3

# Package information
PACKAGE_NAME = whisper-dvr
VERSION = $(shell grep -E "^;; Version:" whisper-dvr.el | sed 's/;; Version: //')

# Documentation tools
MAKEINFO ?= makeinfo
TEXI2PDF ?= texi2pdf

# whisper.el is replaced by a stub so that the tests need no Whisper
# installation.
STUB = --eval "(add-to-list 'load-path \".\")" \
       --eval "(setq whisper-install-whispercpp nil)" \
       --eval "(provide 'whisper)" \
       --eval "(defun whisper-run (&optional _arg) nil)"

.PHONY: all check test test-verbose test-llm test-auto-delete test-replacements \
        test-python test-single lint lint-checkdoc lint-package compile clean \
        help install-deps info pdf html docs skill-data skill-zip

all: compile test lint

## Help target
help:
	@echo "whisper-dvr Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all           Run compile, test, and lint (default)"
	@echo "  check         Run compile, lint, and every test, including Python"
	@echo "  test          Run ERT tests"
	@echo "  test-verbose  Run ERT tests with verbose output"
	@echo "  test-llm      Run only the LLM post-processing tests"
	@echo "  test-auto-delete  Run only the automatic deletion tests"
	@echo "  test-replacements Run the text replacement tests in Emacs and Python"
	@echo "  test-python   Run the Python tests of the Claude skill"
	@echo "  lint          Run package-lint and checkdoc"
	@echo "  compile       Byte-compile the source files"
	@echo "  clean         Remove compiled files"
	@echo "  install-deps  Install development dependencies"
	@echo "  info          Generate Info documentation"
	@echo "  pdf           Generate PDF documentation"
	@echo "  html          Generate HTML documentation"
	@echo "  docs          Generate all documentation formats"
	@echo "  skill-data    Rebuild the skill rules and a proposed deny list"
	@echo "  skill-zip     Package the Claude skill as $(SKILL).zip"
	@echo "  help          Show this help message"

## Install development dependencies
install-deps:
	$(BATCH) --eval "(progn \
	  (require 'package) \
	  (add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t) \
	  (package-initialize) \
	  (package-refresh-contents) \
	  (package-install 'package-lint))"
	$(PYTHON) -m pip install --user pytest wordfreq

## Run tests
test:
	@echo "Running tests..."
	$(BATCH) $(STUB) \
	  -l ert \
	  $(LOAD_SRCS) \
	  $(LOAD_TESTS) \
	  -f ert-run-tests-batch-and-exit

## Run tests with verbose output
test-verbose:
	@echo "Running tests (verbose)..."
	$(BATCH) $(STUB) \
	  -l ert \
	  $(LOAD_SRCS) \
	  $(LOAD_TESTS) \
	  --eval "(ert-run-tests-batch-and-exit t)"

## Run only the LLM post-processing tests
test-llm:
	@echo "Running LLM post-processing tests..."
	$(BATCH) $(STUB) \
	  -l ert \
	  $(LOAD_SRCS) \
	  $(LOAD_TESTS) \
	  --eval "(ert-run-tests-batch-and-exit \"^whisper-dvr-test-llm-\")"

## Run only the automatic deletion tests
test-auto-delete:
	@echo "Running automatic deletion tests..."
	$(BATCH) $(STUB) \
	  -l ert \
	  $(LOAD_SRCS) \
	  $(LOAD_TESTS) \
	  --eval "(ert-run-tests-batch-and-exit \"^whisper-dvr-test-auto-delete-\")"

## Run only the text replacement tests, in Emacs Lisp and in Python
test-replacements: test-python
	@echo "Running text replacement tests..."
	$(BATCH) \
	  --eval "(add-to-list 'load-path \".\")" \
	  -l ert \
	  -l whisper-dvr-replacements.el \
	  -l whisper-dvr-replacements-test.el \
	  -f ert-run-tests-batch-and-exit

## Run the Python tests of the Claude skill
test-python:
	@echo "Running Python skill tests..."
	$(PYTHON) -m pytest -q -p no:cacheprovider $(SKILL_DIR)/tests

## Compile, lint, and test in sequence, for continuous integration
check: compile lint test test-python

## Lint the source files
lint: lint-checkdoc lint-package

lint-checkdoc:
	@echo "Running checkdoc..."
	$(BATCH) \
	  --eval "(require 'checkdoc)" \
	  --eval "(setq sentence-end-double-space nil)" \
	  $(foreach f,$(SRCS),--eval "(checkdoc-file \"$(f)\")")

# whisper.el is installed from GitHub and is in no package archive, so
# package-lint would report it as not installable.  WHISPER_STUB adds a
# stand-in archive entry each time package-initialize runs.  Any other
# missing dependency is still reported.
WHISPER_STUB = (advice-add 'package-initialize :after \
  (lambda (&rest _) \
    (unless (assq 'whisper package-archive-contents) \
      (push (list 'whisper (package-desc-create :name 'whisper :version '(0 1) \
                   :summary \"Speech-to-text with whisper.cpp\" :archive \"github\")) \
            package-archive-contents))))

lint-package:
	@echo "Running package-lint..."
	$(BATCH) \
	  --eval "(require 'package)" \
	  --eval "$(WHISPER_STUB)" \
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
	  $(STUB) \
	  -f batch-byte-compile $(SRCS)

## Clean compiled files
clean:
	@echo "Cleaning..."
	rm -f *.elc
	rm -f *~
	rm -f \#*\#
	rm -f *.aux *.cp *.cps *.fn *.fns *.ky *.log *.pg *.toc *.tp *.vr *.vrs
	rm -f $(SKILL).zip
	rm -rf $(SKILL_DIR)/scripts/__pycache__ $(SKILL_DIR)/tests/__pycache__

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

## Rebuild the skill snapshot from the Voice-In export.  The proposed
## deny list goes beside the edited one so that hand edits survive.
skill-data:
	$(PYTHON) $(SKILL_DIR)/scripts/audit_rules.py $(SKILL_DATA)/replacements.csv \
	  --allow $(SKILL_DATA)/contractions.csv \
	  --deny-out $(SKILL_DATA)/deny-proposed.txt \
	  --rules-out $(SKILL_DATA)/rules.csv
	@test -f $(SKILL_DATA)/deny.txt || cp $(SKILL_DATA)/deny-proposed.txt $(SKILL_DATA)/deny.txt
	@echo "Compare $(SKILL_DATA)/deny-proposed.txt with $(SKILL_DATA)/deny.txt"

## Package the skill for upload to Claude.  The full export is left out
## because the skill reads the filtered rules.csv.
skill-zip:
	rm -f $(SKILL).zip
	cd skills && zip -r ../$(SKILL).zip $(SKILL) \
	  -x '*/__pycache__/*' '*/.pytest_cache/*' '*/data/replacements.csv' \
	     '*/data/deny-proposed.txt' '*.DS_Store'
	@echo "Wrote $(SKILL).zip"

## Run a single test (usage: make test-single TEST=test-name)
test-single:
	@echo "Running single test: $(TEST)"
	$(BATCH) $(STUB) \
	  -l ert \
	  $(LOAD_SRCS) \
	  $(LOAD_TESTS) \
	  --eval "(ert-run-tests-batch-and-exit '$(TEST))"

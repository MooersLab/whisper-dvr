# whisper-dvr
<!-- ![Version](https://img.shields.io/static/v1?label=whisper-dvr&message=0.1&color=brightcolor)-->
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Emacs](https://img.shields.io/badge/Emacs-27.1+-purple.svg)](https://www.gnu.org/software/emacs/)

Transcribe audio files from digital voice recorders directly in Emacs using [whisper.el](https://github.com/natruj/whisper.el).

## Problem addressed: select mp3 file to be transcribed from menu generated from folder on DVR.
This package negates the need to change file paths from that for the current file path to that of the audio file when running whisper-file.
It reduces the friction associated with transcribing multiple audio files daily such as the two associated with morning and evening commutes.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
  - [From MELPA](#from-melpa)
  - [Manual Installation](#manual-installation)
  - [Installing the Info Manual](#installing-the-info-manual)
- [Configuration](#configuration)
- [Usage](#usage)
  - [Tutorial: Basic Transcription Workflow](#tutorial-basic-transcription-workflow)
  - [Tutorial: Batch Processing Multiple Recordings](#tutorial-batch-processing-multiple-recordings)
- [Commands](#commands)
- [Testing](#testing)
  - [Tutorial: Running the Test Suite](#tutorial-running-the-test-suite)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Interactive file selection** with completion showing filename, size, and modification time
- **Multi-format support** for MP3, WAV, and M4A audio files
- **Seamless integration** with whisper.el for high-quality transcription
- **Configurable DVR path** supporting different recorder setups and operating systems
- **Safety checks** preventing accidental overwrites in read-only buffers
- **Comprehensive test suite** with unit and integration tests

## Requirements

- Emacs 27.1 or later
- [whisper.el](https://github.com/natruj/whisper.el) package
- A working Whisper installation ([whisper.cpp](https://github.com/ggerganov/whisper.cpp) or [OpenAI Whisper](https://github.com/openai/whisper))

## Installation

### From MELPA

Once available on MELPA, install using your preferred method:

**Using `package.el`:**

```
M-x package-refresh-contents RET
M-x package-install RET whisper-dvr RET
```

**Using `use-package`:**

Obviously, we need to customize whisper-dvr-directory to that of your device.

```elisp
(use-package whisper-dvr
  :ensure t
  :after whisper
  :custom
  (whisper-dvr-directory "/Volumes/IC RECORDER/REC_FILE/FOLDER01"))
```

**Using `straight.el`:**

```elisp
(straight-use-package
 '(whisper-dvr :type git :host github :repo "MooersLab/whisper-dvr"))
```

### Manual Installation

1. Clone the repository:

```bash
git clone https://github.com/MooersLab/whisper-dvr.git ~/.emacs.d/site-lisp/whisper-dvr
```

2. Add to your init file:

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/whisper-dvr")
(require 'whisper-dvr)
```

### Installing the Info Manual

The package includes a comprehensive Info manual accessible from within Emacs.

#### Building from Source

1. Navigate to the package directory:

```bash
cd ~/.emacs.d/site-lisp/whisper-dvr
```

2. Build the Info file:

```bash
make info
```

3. Install system-wide (requires root):

```bash
sudo make install-info
```

Or install to a user directory:

```bash
make install-info PREFIX=~/.local
```

4. Add the directory to your Info path (if using a user directory):

```elisp
(add-to-list 'Info-additional-directory-list "~/.local/share/info")
```

#### Accessing the Manual

Once installed, access the manual within Emacs:

```
C-h i m whisper-dvr RET
```

Or use:

```
M-x info-display-manual RET whisper-dvr RET
```

## Configuration

### Basic Configuration

Set the path to your DVR's recording directory:

```elisp
(setq whisper-dvr-directory "/Volumes/IC RECORDER/REC_FILE/FOLDER01")
```

### Platform-Specific Paths

**macOS (Sony IC Recorder):**

```elisp
(setq whisper-dvr-directory "/Volumes/IC RECORDER/REC_FILE/FOLDER01")
```

**Linux:**

```elisp
(setq whisper-dvr-directory "/media/username/IC_RECORDER/VOICE")
```

**Windows:**

```elisp
(setq whisper-dvr-directory "E:/REC_FILE/FOLDER01")
```

### Supported File Extensions

By default, whisper-dvr supports MP3, WAV, and M4A files. Add additional formats:

```elisp
(setq whisper-dvr-file-extensions '("mp3" "wav" "m4a" "ogg" "flac"))
```

### Complete Configuration Example

```elisp
(use-package whisper-dvr
  :ensure t
  :after whisper
  :bind (("C-c w d" . whisper-dvr)
         ("C-c w D" . whisper-dvr-set-directory))
  :custom
  (whisper-dvr-directory "/Volumes/IC RECORDER/REC_FILE/FOLDER01")
  (whisper-dvr-file-extensions '("mp3" "wav" "m4a")))
```

## Usage

### Tutorial: Basic Transcription Workflow

This tutorial walks you through transcribing a recording from your digital voice recorder.

#### Step 1: Connect Your DVR

Connect your digital voice recorder to your computer via USB. Verify it is mounted:

**macOS:**
```bash
ls /Volumes/
# Should show "IC RECORDER" or your device name
```

**Linux:**
```bash
ls /media/$USER/
# Should show your device name
```

#### Step 2: Prepare Your Buffer

Open or create a file where you want the transcription to appear:

```
C-x C-f ~/notes/meeting-notes.org RET
```

Position your cursor where you want the transcription inserted.

#### Step 3: Run whisper-dvr

Invoke the transcription command:

```
M-x whisper-dvr RET
```

You will see a completion list showing your recordings:

```
Select audio file (5 available):
recording001.mp3                          2.1M  2024-01-15 10:30
recording002.mp3                          1.8M  2024-01-15 14:45
recording003.mp3                          3.2M  2024-01-16 09:00
...
```

#### Step 4: Select and Transcribe

Use completion (TAB, arrow keys, or type to filter) to select your recording, then press RET.

The transcription will be inserted at point after processing completes.

#### Step 5: Review and Edit

Review the transcription and make any necessary corrections. Save your file:

```
C-x C-s
```

### Tutorial: Batch Processing Multiple Recordings

For processing multiple recordings efficiently:

#### Method 1: Sequential Processing

1. Create a new org file for all transcriptions:

```
C-x C-f ~/transcriptions/batch-2024-01.org RET
```

2. Add a heading for each recording:

```org
* Recording 001 - Morning Meeting
<cursor here>

* Recording 002 - Afternoon Session
<cursor here>
```

3. Position cursor under each heading and run `M-x whisper-dvr` for each.

#### Method 2: Using Keyboard Macros

1. Start recording a macro:

```
C-x (
```

2. Perform one transcription:

```
M-x whisper-dvr RET <select file> RET
C-n C-n  ;; Move down past transcription
```

3. End macro recording:

```
C-x )
```

4. Repeat for remaining files:

```
C-x e e e  ;; Run macro multiple times
```

## Commands

| Command | Description |
|---------|-------------|
| `whisper-dvr` | List audio files from DVR and transcribe selected file |
| `whisper-dvr-set-directory` | Interactively change the DVR directory |

### whisper-dvr

Main command for transcription. Lists all audio files in the configured DVR directory with filename, size, and modification time. After selection, calls `whisper-file` from whisper.el to perform transcription.

**Safety checks:**
- Rejects read-only buffers
- Warns if buffer is not visiting a file

### whisper-dvr-set-directory

Change the DVR directory interactively:

```
M-x whisper-dvr-set-directory RET /new/path/to/dvr RET
```

## Testing

The package includes a comprehensive ERT test suite in `whisper-dvr-test.el`.

### Tutorial: Running the Test Suite

#### Prerequisites

Ensure you have the package files:
- `whisper-dvr.el`
- `whisper-dvr-test.el`

#### Running Tests from Command Line

Using make (recommended):

```bash
cd /path/to/whisper-dvr

# Run all tests
make test

# Run tests with verbose output
make test-verbose

# Run tests without requiring whisper.el
make test-standalone
```

#### Running Tests from Emacs

1. Load the test file:

```elisp
(load-file "/path/to/whisper-dvr-test.el")
```

2. Run all tests:

```
M-x ert RET t RET
```

3. Run specific test categories:

```
;; Run only unit tests for the main function
M-x ert RET whisper-dvr-test-rejects RET

;; Run integration tests
M-x ert RET whisper-dvr-test-integration RET
```

#### Understanding Test Output

Successful run:
```
Running 20 tests (2024-01-15 10:30:00)
   passed  20/20  whisper-dvr-test-edge-case-zero-size-file (0.001 sec)

Ran 20 tests, 20 results as expected (2024-01-15 10:30:01)
```

Failed test example:
```
F whisper-dvr-test-default-directory
    Test failed: ((should (stringp whisper-dvr-directory))
                  :value nil)
```

#### Test Categories

| Category | Tests | Description |
|----------|-------|-------------|
| Custom Variables | 2 | Default values of configuration options |
| List Audio Files | 4 | File listing and filtering |
| Format File Entry | 3 | Display formatting |
| Set Directory | 2 | Directory configuration |
| Main Function | 3 | Core functionality |
| Integration | 4 | End-to-end workflows |
| Edge Cases | 3 | Unusual inputs |

#### Running Linting Checks

```bash
# Run all linting
make lint

# Run package-lint only
make lint-package

# Run checkdoc only
make lint-checkdoc
```

#### Continuous Integration

For CI/CD pipelines, use:

```bash
make check
```

This runs byte-compilation, linting, and tests in sequence.

## File Structure

```
whisper-dvr/
├── whisper-dvr.el          # Main package file
├── whisper-dvr-test.el     # ERT test suite
├── whisper-dvr.texi        # Texinfo documentation source
├── whisper-dvr.info        # Compiled Info manual (generated)
├── Makefile                # Build and test automation
├── README.md               # This file
└── LICENSE                 # GPL-3.0 license
```

## Troubleshooting

### DVR Directory Not Found

**Error:** `DVR directory does not exist: /Volumes/IC RECORDER/...`

**Solution:** Check that your DVR is connected and mounted, then update the path:

```
M-x whisper-dvr-set-directory RET /correct/path RET
```

### No Audio Files Found

**Error:** `No audio files found in ...`

**Solution:** Verify your DVR stores files in a supported format, or add extensions:

```elisp
(add-to-list 'whisper-dvr-file-extensions "wma")
```

### Buffer is Read-Only

**Error:** `Current buffer is read-only; cannot insert transcription`

**Solution:** Switch to a writable buffer or toggle read-only mode:

```
M-x read-only-mode RET
```

## Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Run tests: `make check`
5. Commit with a descriptive message
6. Push to your fork
7. Open a pull request

### Code Style

- Follow Emacs Lisp conventions
- Include docstrings for all public functions
- Add tests for new functionality
- Run `make lint` before submitting

## License

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [whisper.el](https://github.com/natruj/whisper.el) for Whisper integration in Emacs
- [OpenAI Whisper](https://github.com/openai/whisper) for the transcription model
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for the efficient C++ implementation

## Status

Runs on macOS. Not tested on Windows or Linux.

## Update history

|Version      | Changes                                                                                                                                                                         | Date                 |
|:-----------|:------------------------------------------------------------------------------------------------------------------------------------------|:--------------------|
| Version 0.1 |   Added badges, funding, and update table.  Initial commit.                                                                                                                | 1/30/2026  |
## Sources of funding

- NIH: R01 CA242845
- NIH: R01 AI088011
- NIH: P30 CA225520 (PI: R. Mannel)
- NIH: P20 GM103640 and P30 GM145423 (PI: A. West)

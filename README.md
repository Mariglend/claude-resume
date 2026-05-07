# claude-resume 🔄

**Auto-resume Claude Code when you hit the rate limit** — no more lost sessions, no more babysitting the terminal.

When Claude Code exhausts your token quota mid-task, `claude-resume` detects the interruption, waits the exact right amount of time, and automatically resumes from where it left off — passing Claude the last output as context so it can continue seamlessly.

---

## The Problem

You're running a long Claude Code task — refactoring a module, writing a test suite, generating documentation — and halfway through:

```
Error: rate_limit_error — Too many requests. Try again in 4m 30s.
```

You lose all progress and have to start over, or sit there watching the terminal.

## The Solution

```bash
./claude_resume.sh "refactor the auth module in src/auth.py and write tests"
```

That's it. `claude-resume` handles the rest.

---

## Features

- 🔍 **Smart rate limit detection** — catches `429`, `rate_limit_error`, `too many requests`, `try again in`, and more
- ⏱️ **Exact wait time extraction** — reads the retry delay from Claude's error message (e.g. `4m 30s`) with a small buffer, no guessing
- ⏳ **Live countdown** — shows `⏳ Resuming in 04m 23s...` updating in real time
- 🔁 **Context-aware continuation** — on retry, sends Claude the original task + last ~800 chars of output so it knows exactly where it stopped
- 💾 **Session state** — saves `claude_session_state.json` after every attempt so nothing is lost even if the script itself crashes
- 📋 **Full logging** — timestamped log file for every run
- 🛠️ **Two implementations** — Bash (zero deps) and Python (more robust, configurable via CLI flags)

---

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude` command available in PATH)
- Bash 4+ **or** Python 3.8+
- No other dependencies

---

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/claude-resume.git
cd claude-resume
chmod +x claude_resume.sh
```

Optionally, add to your PATH:

```bash
# add to ~/.bashrc or ~/.zshrc
export PATH="$PATH:/path/to/claude-resume"
```

---

## Usage

### Bash version

```bash
./claude_resume.sh "your task description"

# With extra Claude Code flags
./claude_resume.sh "refactor src/auth.py" --model claude-opus-4-5
```

Edit the config block at the top of the script to change defaults:

```bash
MAX_RETRIES=20     # how many times to retry before giving up
RETRY_DELAY=60     # minimum wait in seconds if no delay is found in the error
CHECK_INTERVAL=30  # countdown update frequency in seconds
```

### Python version

```bash
python3 claude_resume.py "your task description"

# Full options
python3 claude_resume.py "write unit tests for utils.py" \
  --max-retries 15 \
  --retry-delay 90 \
  --check-interval 15 \
  --model claude-opus-4-5
```

```
options:
  --max-retries N      Max retry attempts (default: 20)
  --retry-delay SEC    Min wait in seconds when delay not detected (default: 60)
  --check-interval SEC Countdown update interval (default: 30)
  Any remaining args are passed directly to claude
```

---

## How it works

```
Attempt 1: Run original prompt
    └─ Rate limit hit → extract wait time from error message
       └─ Countdown (live) → wait with buffer
          └─ Attempt 2: Send original prompt + last 800 chars of output
             └─ Claude continues from where it stopped
                └─ Success ✓  (or repeat if rate limited again)
```

On continuation attempts, the prompt sent to Claude looks like this:

> I was working on a task and was interrupted by a rate limit. Continue exactly from where you left off without repeating completed work.
>
> **ORIGINAL TASK:** `[your original prompt]`
>
> **LAST OUTPUT BEFORE INTERRUPTION:**
> `[last ~800 characters]`

---

## Output files

| File | Description |
|------|-------------|
| `claude_resume_YYYYMMDD_HHMMSS.log` | Full timestamped log of the session |
| `claude_session_state.json` | Last known state (prompt, attempt number, output snippet) |

---

## Tips

- Works best for **incremental tasks** (writing files, generating code, editing documents) where Claude can clearly see what's already been done
- For very long tasks, consider breaking them into smaller subtasks and running each through `claude-resume`
- The `--max-retries` default of 20 is intentionally high — Claude's rate limits usually reset within a few minutes

---

## License

MIT — see [LICENSE](LICENSE)

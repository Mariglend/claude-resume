#!/usr/bin/env python3
"""
claude_resume.py — Auto-resume Claude Code quando finisci i token
==================================================================
USO:
    python claude_resume.py "il tuo prompt"
    python claude_resume.py "refactora src/auth.py" --max-retries 15 --model claude-opus-4-5

DIPENDENZE: solo stdlib Python 3.8+
"""

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

# ── ANSI colors ───────────────────────────────────────────────────────────────
RED     = "\033[0;31m"
YELLOW  = "\033[1;33m"
GREEN   = "\033[0;32m"
CYAN    = "\033[0;36m"
BOLD    = "\033[1m"
RESET   = "\033[0m"

# ── Patterns che indicano rate limit ─────────────────────────────────────────
RATE_LIMIT_PATTERNS = [
    r"rate.?limit",
    r"too many requests",
    r"429",
    r"quota exceeded",
    r"usage limit",
    r"try again in",
    r"rate_limit_error",
    r"overloaded",
    r"capacity",
]

def log(level: str, msg: str, log_file: Path):
    ts = datetime.now().strftime("%H:%M:%S")
    icons = {"INFO": f"{CYAN}ℹ{RESET}", "OK": f"{GREEN}✓{RESET}",
             "WARN": f"{YELLOW}⚠{RESET}", "ERROR": f"{RED}✗{RESET}"}
    icon = icons.get(level, "·")
    line = f"[{ts}] {icon} {msg}"
    print(line)
    with open(log_file, "a") as f:
        # Versione senza ANSI per il file
        clean = re.sub(r"\033\[[0-9;]*m", "", line)
        f.write(clean + "\n")


def is_rate_limit(text: str) -> bool:
    text_lower = text.lower()
    return any(re.search(p, text_lower) for p in RATE_LIMIT_PATTERNS)


def extract_wait_seconds(text: str, default: int) -> int:
    """Prova a leggere il wait time dal messaggio di errore."""
    # "try again in 1m 30s"
    m = re.search(r"try again in\s+(?:(\d+)m\s*)?(?:(\d+)s)?", text, re.I)
    if m:
        mins = int(m.group(1) or 0)
        secs = int(m.group(2) or 0)
        total = mins * 60 + secs
        if total > 0:
            return max(int(total * 1.1) + 5, default)

    # "retry after 90"
    m = re.search(r"retry after\s+(\d+)", text, re.I)
    if m:
        total = int(m.group(1))
        return max(int(total * 1.1) + 5, default)

    return default


def countdown(seconds: int, check_interval: int = 30):
    """Mostra un countdown aggiornato ogni check_interval secondi."""
    end = time.time() + seconds
    while True:
        remaining = int(end - time.time())
        if remaining <= 0:
            break
        mins, secs = divmod(remaining, 60)
        print(f"\r{YELLOW}  ⏳ Riprendo tra {mins:02d}m {secs:02d}s...{RESET}   ", end="", flush=True)
        sleep_time = min(check_interval, remaining)
        time.sleep(sleep_time)
    print(f"\r{GREEN}  ✓ Attesa completata, riprendo!                    {RESET}")


def build_prompt(original: str, attempt: int, last_output: str) -> str:
    if attempt == 1:
        return original
    snippet = last_output[-800:] if len(last_output) > 800 else last_output
    return f"""Stavo lavorando a questo task e mi sono interrotto per rate limit. \
Continua esattamente da dove ti sei fermato senza ripetere il lavoro già completato.

TASK ORIGINALE:
{original}

ULTIMO OUTPUT PRIMA DELL'INTERRUZIONE (ultimi ~800 caratteri):
---
{snippet}
---

Continua il lavoro dal punto di interruzione. Se hai già completato il task, confermalo brevemente."""


def save_session(path: Path, prompt: str, attempt: int, last_output: str):
    data = {
        "prompt": prompt,
        "attempt": attempt,
        "timestamp": datetime.now().isoformat(),
        "last_output_snippet": last_output[-500:],
    }
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))


def run_claude(prompt: str, extra_args: list[str]) -> tuple[str, int]:
    """Esegue `claude --print` e restituisce (output, exit_code)."""
    cmd = ["claude", "--print"] + extra_args
    try:
        result = subprocess.run(
            cmd,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=600,  # 10 minuti max per singola esecuzione
        )
        output = result.stdout + result.stderr
        return output.strip(), result.returncode
    except subprocess.TimeoutExpired:
        return "ERROR: timeout dopo 600 secondi", 1
    except FileNotFoundError:
        return "ERROR: comando 'claude' non trovato. Installa Claude Code CLI.", 127


def main():
    parser = argparse.ArgumentParser(
        description="Auto-resume Claude Code quando finisci i token"
    )
    parser.add_argument("prompt", help="Il task da eseguire con Claude Code")
    parser.add_argument("--max-retries", type=int, default=20, metavar="N",
                        help="Numero massimo di tentativi (default: 20)")
    parser.add_argument("--retry-delay", type=int, default=60, metavar="SEC",
                        help="Secondi minimi di attesa tra tentativi (default: 60)")
    parser.add_argument("--check-interval", type=int, default=30, metavar="SEC",
                        help="Secondi tra aggiornamenti countdown (default: 30)")
    # Passa tutto il resto a claude
    parser.add_argument("extra", nargs=argparse.REMAINDER,
                        help="Argomenti extra passati a claude (es. --model ...)")
    args = parser.parse_args()

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_file    = Path(f"claude_resume_{ts}.log")
    session_file = Path("claude_session_state.json")

    extra_args = [a for a in args.extra if a != "--"]

    print()
    print(f"{BOLD}{CYAN}╔══════════════════════════════════════════╗{RESET}")
    print(f"{BOLD}{CYAN}║     Claude Code — Auto Resume Script     ║{RESET}")
    print(f"{BOLD}{CYAN}╚══════════════════════════════════════════╝{RESET}")
    print()

    prompt_preview = args.prompt[:80] + ("..." if len(args.prompt) > 80 else "")
    log("INFO", f"Prompt: {BOLD}{prompt_preview}{RESET}", log_file)
    log("INFO", f"Log: {log_file}", log_file)
    log("INFO", f"Max tentativi: {args.max_retries}", log_file)
    print()

    last_output = ""
    task_done   = False

    for attempt in range(1, args.max_retries + 1):
        print()
        log("INFO", f"{BOLD}Tentativo {attempt} / {args.max_retries}{RESET}", log_file)

        current_prompt = build_prompt(args.prompt, attempt, last_output)
        output, exit_code = run_claude(current_prompt, extra_args)
        last_output = output
        save_session(session_file, args.prompt, attempt, output)

        # Mostra output
        print()
        if len(output) > 2000:
            print(output[:1000])
            print(f"{CYAN}  [...output troncato...]{RESET}")
            print(output[-500:])
        else:
            print(output)
        print()

        # ── Analisi risultato ─────────────────────────────────────────────────
        if is_rate_limit(output):
            wait = extract_wait_seconds(output, args.retry_delay)
            log("WARN", f"Rate limit al tentativo {attempt}. Attendo {BOLD}{wait}s{RESET}...", log_file)
            countdown(wait, args.check_interval)

        elif exit_code == 0:
            log("OK", f"{BOLD}✅ Task completato al tentativo {attempt}!{RESET}", log_file)
            task_done = True
            break

        else:
            log("ERROR", f"Exit code {exit_code} (non rate limit). Attendo {args.retry_delay}s...", log_file)
            countdown(args.retry_delay, args.check_interval)

    # ── Risultato finale ──────────────────────────────────────────────────────
    print()
    print(f"{BOLD}{CYAN}{'═'*46}{RESET}")
    if task_done:
        log("OK", f"{BOLD}Completato!{RESET} Log: {log_file}", log_file)
        sys.exit(0)
    else:
        log("ERROR", f"Raggiunto il limite di {args.max_retries} tentativi.", log_file)
        log("ERROR", f"Stato salvato in: {session_file}", log_file)
        sys.exit(1)


if __name__ == "__main__":
    main()

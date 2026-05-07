#!/usr/bin/env bash
# =============================================================================
# claude_resume.sh — Auto-resume Claude Code when rate limit expires
# =============================================================================
# USAGE:
#   chmod +x claude_resume.sh
#   ./claude_resume.sh "il tuo prompt" [opzioni extra di claude]
#
# ESEMPI:
#   ./claude_resume.sh "refactora il modulo auth in src/auth.py"
#   ./claude_resume.sh "scrivi i test per utils.py" --model claude-opus-4-5
#
# DIPENDENZE: claude (Claude Code CLI), jq (opzionale, per parsing migliore)
# =============================================================================

set -euo pipefail

# ── Colori ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Config (modificabile) ─────────────────────────────────────────────────────
MAX_RETRIES=20          # quante volte riprovare prima di arrendersi
RETRY_DELAY=60          # secondi di attesa minima tra i tentativi
CHECK_INTERVAL=30       # secondi tra un controllo e l'altro durante l'attesa
LOG_FILE="./claude_resume_$(date +%Y%m%d_%H%M%S).log"
SESSION_FILE="./claude_session_state.json"

# ── Argomenti ─────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo -e "${RED}Errore: devi fornire un prompt.${RESET}"
    echo "Uso: $0 \"il tuo prompt\" [opzioni claude]"
    exit 1
fi

PROMPT="$1"
shift
EXTRA_ARGS=("$@")

# ── Funzioni helper ───────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo -e "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log_info()    { log "${CYAN}ℹ ${RESET}$*"; }
log_ok()      { log "${GREEN}✓ ${RESET}$*"; }
log_warn()    { log "${YELLOW}⚠ ${RESET}$*"; }
log_error()   { log "${RED}✗ ${RESET}$*"; }

is_rate_limit_error() {
    local output="$1"
    echo "$output" | grep -qiE \
        "rate.?limit|too many requests|429|quota exceeded|usage limit|token limit|try again in|rate_limit_error" \
        && return 0 || return 1
}

extract_wait_time() {
    # Prova a estrarre "retry after X seconds" o "try again in Xm Xs"
    local output="$1"
    local seconds=0

    # Pattern: "try again in 1m 30s" o "retry after 90s"
    if echo "$output" | grep -qiE "try again in ([0-9]+)m ([0-9]+)s"; then
        local mins secs
        mins=$(echo "$output" | grep -ioE "([0-9]+)m" | grep -oE "[0-9]+" | head -1)
        secs=$(echo "$output" | grep -ioE "([0-9]+)s" | grep -oE "[0-9]+" | head -1)
        seconds=$(( ${mins:-0} * 60 + ${secs:-0} ))
    elif echo "$output" | grep -qiE "retry after ([0-9]+)"; then
        seconds=$(echo "$output" | grep -ioE "retry after ([0-9]+)" | grep -oE "[0-9]+" | head -1)
    fi

    # Aggiungi buffer del 10% e minimo RETRY_DELAY
    if [[ $seconds -gt 0 ]]; then
        seconds=$(( seconds + seconds / 10 + 5 ))
        echo $(( seconds > RETRY_DELAY ? seconds : RETRY_DELAY ))
    else
        echo "$RETRY_DELAY"
    fi
}

save_session() {
    local attempt="$1"
    local last_output="$2"
    cat > "$SESSION_FILE" <<EOF
{
  "prompt": $(echo "$PROMPT" | jq -Rs . 2>/dev/null || echo "\"$PROMPT\""),
  "attempt": $attempt,
  "timestamp": "$(date -Iseconds)",
  "last_output_snippet": $(echo "${last_output: -500}" | jq -Rs . 2>/dev/null || echo "\"\"")
}
EOF
}

countdown() {
    local wait_secs="$1"
    local end_time=$(( $(date +%s) + wait_secs ))

    while true; do
        local now=$(date +%s)
        local remaining=$(( end_time - now ))
        [[ $remaining -le 0 ]] && break

        local mins=$(( remaining / 60 ))
        local secs=$(( remaining % 60 ))
        printf "\r${YELLOW}  ⏳ Riprendo tra %02dm %02ds...${RESET}   " "$mins" "$secs"
        sleep "$CHECK_INTERVAL"

        # Ricontrolla ogni CHECK_INTERVAL
        now=$(date +%s)
        remaining=$(( end_time - now ))
        [[ $remaining -le 0 ]] && break
    done
    printf "\r${GREEN}  ✓ Tempo scaduto, riprendo!                    ${RESET}\n"
}

build_continuation_prompt() {
    local attempt="$1"
    local last_output="$2"

    if [[ $attempt -eq 1 ]]; then
        # Prima esecuzione: prompt originale
        echo "$PROMPT"
    else
        # Esecuzioni successive: chiedi di continuare
        local snippet="${last_output: -800}"
        cat <<EOF
Stavo lavorando a questo task e mi sono interrotto per rate limit. Continua esattamente da dove ti sei fermato senza ripetere il lavoro già completato.

TASK ORIGINALE:
$PROMPT

ULTIMO OUTPUT PRIMA DELL'INTERRUZIONE (ultimi ~800 caratteri):
---
$snippet
---

Continua il lavoro dal punto di interruzione. Se hai già completato il task, confermalo brevemente.
EOF
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║     Claude Code — Auto Resume Script     ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"
echo ""
log_info "Prompt: ${BOLD}${PROMPT:0:80}${RESET}$([ ${#PROMPT} -gt 80 ] && echo '...')"
log_info "Log salvato in: $LOG_FILE"
log_info "Max tentativi: $MAX_RETRIES"
echo ""

# Verifica che claude sia disponibile
if ! command -v claude &> /dev/null; then
    log_error "Claude Code CLI non trovato. Installa con: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

attempt=0
last_output=""
task_completed=false

while [[ $attempt -lt $MAX_RETRIES ]]; do
    attempt=$(( attempt + 1 ))

    echo ""
    log_info "${BOLD}Tentativo $attempt / $MAX_RETRIES${RESET}"

    # Costruisci il prompt (originale al primo tentativo, continuation dopo)
    current_prompt=$(build_continuation_prompt "$attempt" "$last_output")

    # Esegui Claude Code
    set +e
    output=$(echo "$current_prompt" | claude --print "${EXTRA_ARGS[@]}" 2>&1)
    exit_code=$?
    set -e

    last_output="$output"
    save_session "$attempt" "$output"

    # Mostra output (troncato se troppo lungo)
    echo ""
    if [[ ${#output} -gt 2000 ]]; then
        echo -e "${output:0:1000}"
        echo -e "${CYAN}  [...output troncato per leggibilità...]${RESET}"
        echo -e "${output: -500}"
    else
        echo "$output"
    fi
    echo ""

    # ── Analisi risultato ─────────────────────────────────────────────────────
    if is_rate_limit_error "$output"; then
        wait_time=$(extract_wait_time "$output")
        log_warn "Rate limit rilevato al tentativo $attempt."
        log_warn "Attendo ${BOLD}${wait_time}s${RESET} prima di riprovare..."
        echo ""
        countdown "$wait_time"

    elif [[ $exit_code -eq 0 ]]; then
        log_ok "${BOLD}Task completato con successo al tentativo $attempt!${RESET}"
        task_completed=true
        break

    else
        # Errore generico non da rate limit
        log_error "Errore (exit code $exit_code). Non sembra un rate limit."
        log_warn "Attendo ${RETRY_DELAY}s e riprovo comunque..."
        countdown "$RETRY_DELAY"
    fi
done

# ── Risultato finale ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
if $task_completed; then
    log_ok "${BOLD}✅ Completato dopo $attempt tentativo/i.${RESET}"
else
    log_error "❌ Raggiunto il limite di $MAX_RETRIES tentativi senza completare."
    log_error "Controlla il log: $LOG_FILE"
    log_error "Stato sessione: $SESSION_FILE"
    exit 1
fi
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
echo ""

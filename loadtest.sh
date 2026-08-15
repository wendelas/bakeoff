#!/usr/bin/env bash
# Teste de carga em rampa — descobre ONDE o provedor satura.
#
#   ./loadtest.sh https://fly.monstrecos.com
#   ./loadtest.sh https://fly.monstrecos.com /cpu
#   REQS_POR_WORKER=50 ./loadtest.sh https://fly.monstrecos.com /health
#
# POR QUE ESTA VERSAO E DIFERENTE DA ANTERIOR:
# A primeira versao criava um processo `curl` por requisicao. No Git Bash
# do Windows, criar processo custa ~200ms — mais que a propria requisicao.
# Voce mediria a sua maquina forkando, nao o servidor respondendo.
#
# Aqui cada worker e UM processo curl que faz N requisicoes em serie,
# reaproveitando a conexao TCP/TLS. Tambem e mais realista: e assim que
# um navegador se comporta.
#
# O sinal que interessa NAO e "quantas req/s" — e em qual nivel de
# concorrencia o p95 dispara enquanto o p50 fica estavel. Isso e fila.
#
# ATENCAO: rode contra o SEU proprio servico. Teste de carga contra
# terceiros e ataque.

export LC_ALL=C
set -uo pipefail

URL="${1:-}"
EP="${2:-/health}"
[[ -z "$URL" ]] && { echo "uso: ./loadtest.sh https://host [endpoint]"; exit 1; }

NIVEIS=(1 5 10 25 50)
REQS_POR_WORKER="${REQS_POR_WORKER:-30}"
OUT="${OUT:-carga.csv}"

command -v curl >/dev/null || { echo "curl ausente"; exit 1; }

[[ -f "$OUT" ]] || echo "timestamp,url,endpoint,concorrencia,total,ok,erros,rps,p50_ms,p95_ms,p99_ms,duracao_s" > "$OUT"

# Um worker = um processo curl fazendo N requisicoes sequenciais.
# A URL repetida N vezes faz o curl reusar a conexao (keep-alive).
worker() {
  local args=()
  local i
  # Cada URL precisa do SEU proprio -o /dev/null. Com um so, apenas a
  # primeira resposta e descartada e as demais vazam o corpo na saida,
  # quebrando o parsing do awk.
  for ((i = 0; i < REQS_POR_WORKER; i++)); do
    args+=(-o /dev/null "$URL$EP")
  done
  curl -sS --max-time 20 -w '%{http_code} %{time_total}\n' "${args[@]}" 2>/dev/null
}

echo "alvo:              $URL$EP"
echo "reqs por worker:   $REQS_POR_WORKER"
echo ""
printf '%-6s %8s %8s %8s %9s %10s %10s %8s\n' "CONC" "REQS" "OK" "ERROS" "RPS" "p50" "p95" "TEMPO"
printf '%s\n' "---------------------------------------------------------------------------"

for c in "${NIVEIS[@]}"; do
  dir="$(mktemp -d)"
  ini_ns=$(date +%s%N)

  # Cada worker grava no PROPRIO arquivo. Append concorrente com >>
  # nao e atomico no Git Bash — os workers sobrescrevem uns aos outros
  # e voce perde quase todas as amostras.
  for w in $(seq 1 "$c"); do worker > "$dir/w$w.txt" & done
  wait

  tmp="$dir/todos.txt"
  cat "$dir"/w*.txt > "$tmp" 2>/dev/null || : 

  fim_ns=$(date +%s%N)
  dec=$(awk -v a="$ini_ns" -v b="$fim_ns" 'BEGIN { d = (b - a) / 1e9; print (d < 0.001 ? 0.001 : d) }')

  linha="$(awk -v d="$dec" '
    { t[NR] = $2 + 0; if ($1 ~ /^2/) ok++; else err++ }
    END {
      n = NR
      if (n == 0) { print "0 0 0 0 0 0 0"; exit }
      for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
          if (t[i] > t[j]) { x = t[i]; t[i] = t[j]; t[j] = x }
      idx50 = int(n * 0.50); if (idx50 < 1) idx50 = 1
      idx95 = int(n * 0.95); if (idx95 < 1) idx95 = 1
      idx99 = int(n * 0.99); if (idx99 < 1) idx99 = 1
      printf "%d %d %d %.1f %.0f %.0f %.0f",
        n, ok + 0, err + 0, n / d, t[idx50] * 1000, t[idx95] * 1000, t[idx99] * 1000
    }' "$tmp")"

  read -r total ok erros rps p50 p95 p99 <<< "$linha"

  printf '%-6s %8s %8s %8s %9s %7s ms %7s ms %6.1fs\n' \
    "$c" "$total" "$ok" "$erros" "$rps" "$p50" "$p95" "$dec"
  echo "$(date -Iseconds),$URL,$EP,$c,$total,$ok,$erros,$rps,$p50,$p95,$p99,$dec" >> "$OUT"

  rm -rf "$dir"
  sleep 5
done

echo ""
echo "-> gravado em $OUT"
echo ""
echo "Como ler:"
echo "  RPS cresce proporcional a CONC   -> ainda tem folga"
echo "  RPS parou de crescer             -> saturou aqui"
echo "  p95 disparou, p50 estavel        -> fila se formando"
echo "  erros > 0                        -> passou do limite"
echo "  p50 e p95 sobem juntos           -> CPU no talo"
echo ""
echo "Se o RPS nao cresceu nem no nivel 5, o gargalo e a SUA maquina"
echo "ou banda — nao o servidor. Rode de um VPS para medir de verdade."
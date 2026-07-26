#!/usr/bin/env bash
# Coleta de metricas do bake-off -> CSV
#
# Uso:
#   ./measure.sh                 uma rodada
#   ./measure.sh --watch 900     a cada 15 min, indefinidamente
#   ./measure.sh --runs 5        5 rodadas seguidas (descarta a 1a)
#
# IMPORTANTE: rodar da SUA maquina em Brasilia. Runner de CI fica nos
# EUA e vai mentir a seu favor sobre latencia.

set -uo pipefail

TARGETS="${TARGETS:-targets.txt}"
OUT="${OUT:-resultados.csv}"
ENDPOINTS=(/health /db /cpu /payload)
WATCH=0; INTERVAL=900; RUNS=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch) WATCH=1; INTERVAL="${2:-900}"; shift 2 ;;
    --runs)  RUNS="${2:-3}"; shift 2 ;;
    *) echo "argumento desconhecido: $1"; exit 1 ;;
  esac
done

[[ -f "$TARGETS" ]] || { echo "arquivo $TARGETS nao encontrado"; exit 1; }

if [[ ! -f "$OUT" ]]; then
  echo "timestamp,provedor,endpoint,http,dns_ms,conn_ms,tls_ms,ttfb_ms,total_ms,bytes,server_ms,cf_pop" > "$OUT"
fi

probe() {
  local nome="$1" url="$2" ep="$3"
  local tmp; tmp="$(mktemp)"

  # -w com tempos em segundos; convertidos para ms adiante.
  local fmt='%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download}'
  local raw
  raw="$(curl -sS -o "$tmp" -D "$tmp.h" -w "$fmt" \
          --max-time 30 --compressed "$url$ep" 2>/dev/null)" || raw="000 0 0 0 0 0 0"

  read -r code dns conn tls ttfb total bytes <<< "$raw"

  # serverMs vem do proprio app: separa tempo de rede de tempo de processamento
  local server_ms; server_ms="$(grep -o '"serverMs":[0-9.]*' "$tmp" 2>/dev/null | head -1 | cut -d: -f2)"
  # PoP do Cloudflare: confirma que o edge esta em GRU/BSB e nao nos EUA
  local pop; pop="$(grep -i '^cf-ray:' "$tmp.h" 2>/dev/null | tr -d '\r' | awk '{print $2}' | cut -d- -f2)"

  printf '%s,%s,%s,%s,%.1f,%.1f,%.1f,%.1f,%.1f,%s,%s,%s\n' \
    "$(date -Iseconds)" "$nome" "$ep" "$code" \
    "$(bc -l <<< "$dns*1000")" "$(bc -l <<< "$conn*1000")" \
    "$(bc -l <<< "$tls*1000")" "$(bc -l <<< "$ttfb*1000")" \
    "$(bc -l <<< "$total*1000")" "$bytes" "${server_ms:-}" "${pop:-}" >> "$OUT"

  printf '  %-10s %-9s %3s  ttfb %6.1fms  total %6.1fms  %s\n' \
    "$nome" "$ep" "$code" "$(bc -l <<< "$ttfb*1000")" "$(bc -l <<< "$total*1000")" "${pop:-}"
  rm -f "$tmp" "$tmp.h"
}

rodada() {
  echo "== $(date '+%F %T') =="
  # Primeira passada aquece conexao e container; descartada.
  # Sem isso voce mede cold start de um e warm de outro.
  while IFS='|' read -r nome url; do
    [[ -z "${nome// }" || "$nome" == \#* ]] && continue
    curl -s -o /dev/null --max-time 20 "$url/health" 2>/dev/null || true
  done < "$TARGETS"

  for _ in $(seq 1 "$RUNS"); do
    while IFS='|' read -r nome url; do
      [[ -z "${nome// }" || "$nome" == \#* ]] && continue
      for ep in "${ENDPOINTS[@]}"; do probe "$nome" "$url" "$ep"; done
    done < "$TARGETS"
    sleep 2
  done
  echo "-> gravado em $OUT"
}

resumo() {
  echo ""
  echo "== mediana de TTFB por provedor/endpoint (ms) =="
  awk -F, 'NR>1 && $4==200 { k=$2" "$3; v[k]=v[k]" "$8 }
    END { for (k in v) {
      n=split(v[k], a, " "); c=0
      for (i=1;i<=n;i++) if (a[i]!="") b[++c]=a[i]+0
      for (i=1;i<c;i++) for (j=i+1;j<=c;j++) if (b[i]>b[j]) { t=b[i];b[i]=b[j];b[j]=t }
      if (c>0) printf "  %-22s %8.1f  (n=%d)\n", k, b[int((c+1)/2)], c
      delete b
    } }' "$OUT" | sort
}

if [[ "$WATCH" == "1" ]]; then
  trap 'resumo; exit 0' INT
  while true; do rodada; resumo; sleep "$INTERVAL"; done
else
  rodada; resumo
fi

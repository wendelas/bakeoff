#!/usr/bin/env bash
# Coleta de metricas do bake-off -> CSV
#
# Uso:
#   ./measure.sh                 uma rodada
#   ./measure.sh --watch 900     a cada 15 min, indefinidamente
#   ./measure.sh --runs 5        5 rodadas por ciclo
#
# IMPORTANTE: rodar da SUA maquina em Brasilia. Runner de CI fica nos
# EUA e vai mentir a seu favor sobre latencia.
#
# Portabilidade: usa apenas curl + awk. NAO depende de `bc`, que nao
# existe no Git Bash do Windows.
#
# LC_ALL=C e forcado porque em locale pt-BR o separador decimal e
# virgula, e tanto curl quanto printf produzem numeros que quebram o
# parsing ("0,15" nao e numero valido para awk/printf em C locale).

export LC_ALL=C
export LC_NUMERIC=C

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
command -v curl >/dev/null || { echo "curl nao encontrado"; exit 1; }

if [[ ! -f "$OUT" ]]; then
  echo "timestamp,provedor,endpoint,http,dns_ms,conn_ms,tls_ms,ttfb_ms,total_ms,bytes,server_ms,cf_pop" > "$OUT"
fi

# segundos -> ms com uma casa decimal. awk em vez de bc.
to_ms() { awk -v v="${1:-0}" 'BEGIN { printf "%.1f", v * 1000 }'; }

probe() {
  local nome="$1" url="$2" ep="$3"
  local tmp; tmp="$(mktemp)"

  local fmt='%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download}'
  local raw
  raw="$(curl -sS -o "$tmp" -D "$tmp.h" -w "$fmt" \
          --max-time 30 --compressed "$url$ep" 2>/dev/null)" || raw="000 0 0 0 0 0 0"

  local code dns conn tls ttfb total bytes
  read -r code dns conn tls ttfb total bytes <<< "$raw"

  # serverMs vem do proprio app: separa tempo de rede de processamento
  local server_ms
  server_ms="$(grep -o '"serverMs":[0-9.]*' "$tmp" 2>/dev/null | head -1 | cut -d: -f2)"
  # PoP do Cloudflare: confirma se o edge atende de GRU/BSB ou dos EUA
  local pop
  pop="$(grep -i '^cf-ray:' "$tmp.h" 2>/dev/null | tr -d '\r' | awk '{print $2}' | cut -d- -f2)"

  local dns_ms conn_ms tls_ms ttfb_ms total_ms
  dns_ms="$(to_ms "$dns")";  conn_ms="$(to_ms "$conn")"
  tls_ms="$(to_ms "$tls")";  ttfb_ms="$(to_ms "$ttfb")"
  total_ms="$(to_ms "$total")"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -Iseconds)" "$nome" "$ep" "$code" \
    "$dns_ms" "$conn_ms" "$tls_ms" "$ttfb_ms" "$total_ms" \
    "$bytes" "${server_ms:-}" "${pop:-}" >> "$OUT"

  # marca visualmente o que nao e 2xx, para nao passar batido
  local flag=""
  case "$code" in
    2*)      flag="" ;;
    000)     flag="  <- sem resposta" ;;
    52*|53*) flag="  <- ERRO CLOUDFLARE->ORIGEM (cert da origem?)" ;;
    *)       flag="  <- HTTP $code" ;;
  esac

  printf '  %-10s %-9s %3s  ttfb %8s ms  total %8s ms  %-4s%s\n' \
    "$nome" "$ep" "$code" "$ttfb_ms" "$total_ms" "${pop:--}" "$flag"

  rm -f "$tmp" "$tmp.h"
}

rodada() {
  echo "== $(date '+%F %T') =="

  # Primeira passada aquece conexao e container; e descartada.
  # Sem isso voce mede cold start de um e warm de outro.
  while IFS='|' read -r nome url; do
    [[ -z "${nome// }" || "$nome" == \#* ]] && continue
    curl -s -o /dev/null --max-time 20 "$url/health" 2>/dev/null || true
  done < "$TARGETS"

  local i ep
  for i in $(seq 1 "$RUNS"); do
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
  echo "== mediana de TTFB por provedor/endpoint (so respostas 2xx) =="
  awk -F, '
    NR > 1 && $4 ~ /^2[0-9][0-9]$/ {
      k = $2 " " $3
      n[k]++
      v[k, n[k]] = $8 + 0
    }
    END {
      if (length(n) == 0) { print "  (nenhuma resposta 2xx ainda)"; exit }
      for (k in n) {
        c = n[k]
        for (i = 1; i <= c; i++) a[i] = v[k, i]
        for (i = 1; i < c; i++)
          for (j = i + 1; j <= c; j++)
            if (a[i] > a[j]) { t = a[i]; a[i] = a[j]; a[j] = t }
        printf "  %-22s %8.1f ms  (n=%d)\n", k, a[int((c + 1) / 2)], c
      }
    }' "$OUT" | sort

  local erros
  erros="$(awk -F, 'NR>1 && $4 !~ /^2[0-9][0-9]$/ {print $2" HTTP "$4}' "$OUT" \
           | sort | uniq -c | sort -rn | head -6)"
  if [[ -n "$erros" ]]; then
    echo ""
    echo "== respostas nao-2xx (acumulado) =="
    echo "$erros" | sed 's/^/  /'
  fi
}

if [[ "$WATCH" == "1" ]]; then
  trap 'resumo; exit 0' INT
  while true; do rodada; resumo; echo; sleep "$INTERVAL"; done
else
  rodada; resumo
fi
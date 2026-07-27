# Analisando os resultados

## Dois conjuntos de dados

| Arquivo | Origem | O que representa |
|---|---|---|
| `resultados.csv` | sua maquina, Brasilia | o que um usuario BR sente |
| `dados/historico.csv` | runner do GitHub, EUA | comparacao continua 24/7 |

**Nao misture os dois num grafico.** O runner do GitHub fica nos EUA, entao
os numeros absolutos sao diferentes. A coluna `origem` distingue.

## Por que os dois valem

O CI resolve o problema de cobertura: coleta 24/7 sem depender da sua
maquina ligada. Detecta quedas de madrugada, variacao por horario, e
qualquer instabilidade que uma coleta intermitente perderia.

O local resolve o problema de representatividade: e a unica medicao que
diz quanto tempo um visitante brasileiro realmente espera.

Juntos: o CI diz **qual provedor e mais consistente**, o local diz
**quanto isso custa em ms para o seu publico**.

## Calibrando o offset

Rode o `measure.sh` local por uma hora, no mesmo periodo em que o CI
esta rodando. Compare a mediana dos dois para o mesmo provedor:

```
offset = mediana_local - mediana_ci
```

Esse offset e aproximadamente constante por provedor. Com ele, da para
estimar a latencia brasileira de qualquer ponto do historico do CI.

## Consultas uteis

```bash
# mediana por provedor (historico do CI)
awk -F, 'NR>1 && $3=="/health" && $4 ~ /^2/ {print $2, $8}' dados/historico.csv \
  | sort -k1,1 -k2,2n \
  | awk '{a[$1][++n[$1]]=$2} END {for(p in a) print p, a[p][int((n[p]+1)/2)]}'

# uptime por provedor
awk -F, 'NR>1 {t[$2]++; if ($4 ~ /^2/ || $4=="503") ok[$2]++} 
  END {for (p in t) printf "%s %.2f%%\n", p, 100*ok[p]/t[p]}' dados/historico.csv

# variacao por hora do dia (detecta degradacao em horario de pico)
awk -F, 'NR>1 && $3=="/cpu" && $4 ~ /^2/ {split($1,d,"T"); split(d[2],h,":"); 
  soma[h[1]]+=$8; n[h[1]]++} 
  END {for (i in soma) printf "%sh  %.0f ms  (n=%d)\n", i, soma[i]/n[i], n[i]}' \
  dados/historico.csv | sort
```

## Cuidado com o auto-disable

O GitHub desativa workflows agendados apos **60 dias sem atividade** no
repositorio. Para um bake-off de 7 dias, nao e problema. Se estender,
faca um commit qualquer de vez em quando.

Tambem: schedules do GitHub sofrem **atrasos de 10 a 30 minutos** em
horarios de pico. O intervalo de 15 min vai virar 20-40 na pratica.
Para medir latencia isso nao importa — nao e uma tarefa time-critical.

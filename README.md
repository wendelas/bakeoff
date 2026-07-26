# Bake-off probe

App de referência **idêntico** rodando em todos os provedores.
A única variável do experimento deve ser o provedor.

## Endpoints

| Endpoint | Mede |
|---|---|
| `/health` | latência pura de rede e roteamento (sem trabalho) |
| `/db` | ida e volta ao banco |
| `/cpu` | a CPU real recebida (SHA-256, trabalho fixo) |
| `/payload` | throughput e compressão do edge (~127 KB) |

Toda resposta traz `serverMs` e os headers `X-Provider` / `X-Region`.

> Comparar `ttfb` com `serverMs` separa distância de lentidão:
> ttfb alto + serverMs baixo = o problema é a rota, não o provedor.

## Variáveis de ambiente

```
PORT=3000
PROVIDER_NAME=fly          # fly | dokploy | sevalla | railway | gcp | aws | oracle
PROVIDER_REGION=gru
DATABASE_URL=postgres://...
PGSSL=off                  # só se o banco for local sem TLS
```

## Deploy por provedor

### Fly.io

```bash
fly launch --no-deploy --region gru   # revise o fly.toml gerado
fly postgres create --region gru
fly postgres attach <db>              # injeta DATABASE_URL
fly deploy --remote-only
fly certs add fly.monstrecos.com
```

### Railway / Render / Sevalla

Conectar o repo, **forçar build por Dockerfile** (não buildpack),
adicionar Postgres, setar `PROVIDER_NAME` e `PROVIDER_REGION`.

### Dokploy

Criar aplicação apontando para o repo, build type **Dockerfile**.

## Medição

```bash
cp targets.txt.example targets.txt
./measure.sh --watch 900     # a cada 15 min
```

> Rodar da **sua máquina em Brasília**. Runner de CI fica nos EUA e
> mente a seu favor sobre latência.

`Ctrl+C` imprime o resumo. O CSV alimenta as tabelas de métricas de
cada página de provedor no Notion.

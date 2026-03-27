# OpenClaw Setup Kit

Pacote de provisionamento para novas instancias OpenClaw, derivado do baseline operacional observado nos ambientes `root` e `joao`, mas sem copiar personas, memoria, credenciais, alvos, governanca privada ou historico dos agentes atuais.

## Baseline usado

- Imagem validada: `ghcr.io/openclaw/openclaw:latest`
- Runtime mais recente observado no `root`: `org.opencontainers.image.version=2026.3.24`
- Runtime anterior observado no `joao`: `org.opencontainers.image.version=2026.3.13`
- Estrutura de runtime validada:
  - `config -> /home/node/.openclaw`
  - `workspace -> /home/node/.openclaw/workspace`
  - `tools -> /opt/openclaw-tools`
  - `browsers -> /home/node/.cache/ms-playwright`

## O que o kit entrega

- `openclaw.json` sanitizado e renderizavel
- cadeia de modelos com `MiMo` primario e `GPT-5.4` secundario
- isolamento de cron no agente `orquestrador`
- regras de debounce, compaction, memory flush e concorrencia
- bindings basicos para WhatsApp e Web Chat
- allowlist de skills basicas
- templates neutros de instrucoes para `hq` e `orquestrador`
- scripts operacionais copiados do baseline atual e sanitizados para o novo root
- `docker-compose.yml` e `.env.example`

## O que o kit NAO carrega

- personalidades atuais
- `MEMORY.md` real
- `SOUL.md` real
- tokens, contas, JIDs, numeros e aliases atuais
- arquivos de auth/session
- cron jobs operacionais privados dos clientes atuais

## Provisionamento

```powershell
cd D:\Projetos\SANDBOX\apps\openclaw\setup-kit
python .\scripts\render_setup.py `
  --output D:\Projetos\SANDBOX\apps\openclaw\runtime-acme `
  --client-slug acme `
  --display-name "ACME Enterprise" `
  --container-name acme-openclaw `
  --account-id acme-5511999999999 `
  --gateway-token oc_change_me `
  --allowed-origin https://agent.acme.com `
  --gateway-port 18889 `
  --webchat-port 18890
```

Depois:

1. Preencha `.env` a partir de `.env.example`.
2. Suba com `docker compose up -d`.
3. Instale o pacote operacional no host com `bash .\tools\install_whatsapp_ops.sh`.
4. Faça o login do canal WhatsApp e ajuste `groups`/allowlists conforme o cliente.

## Validacao

```powershell
python .\scripts\validate_setup.py
```

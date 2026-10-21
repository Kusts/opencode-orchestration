# ADR research — MXC + Pi 1.1 (issue #43)

> **RESEARCH-ONLY — SEM protótipo, SEM dependência prod.** Este documento é
> pesquisa pura: verificação de claims upstream contra docs/repo primárias,
> threat model, matriz de compatibilidade e decisão registrada. Nenhum
> backend MXC entra em prod por padrão; nenhum wiring MCP novo; Pi apenas
> como eventos/telemetria read-only. Gaps MXC listados na §6 exigem probe em
> runtime exato ANTES de qualquer código.

- **Issue:** #43 — avaliar MXC (Model Context Isolation) + Pi 1.1.
- **Decisão:** **HOLD MXC + ADOPT parcial Pi 1.1.**
- **Status:** research entregue; sem mudança de runtime, sem pin novo, sem flag.
- **Fontes primárias (URLs exatas; revisão `main` vigente em out-2026 —
  commit exato não pinado → UNVERIFIED para reprodução byte-exata):**
  `https://github.com/microsoft/mxc`;
  `https://blogs.windows.com/windowsdeveloper/2026/10/07/microsoft-execution-containers-policy-driven-containment-for-ai-agents/`
  (07-out-2026);
  `https://github.com/microsoft/mxc/blob/main/docs/containment-policy/1.0.0/policy.md`
  (contrato 1.0.0); doc
  `https://github.com/microsoft/mxc/blob/main/docs/logging-access-denied.md`;
  `https://pi.dev/changelog/releases/1.1.0` (05-out-2026),
  `https://pi.dev/docs/latest/terminal-setup#program-status`,
  `https://pi.dev/docs/latest/models#use-classifier-models`,
  `https://pi.dev/docs/latest/llama-cpp#classification`,
  `https://pi.dev/docs/latest/security`,
  `https://pi.dev/docs/latest/extensions`.
- **Fonte secundária (NÃO é evidência primária):**
  `https://cruxdigits.nl/blog/microsoft-execution-containers-evidence/`
  (SECUNDÁRIA); issue HN #1455 citada sem URL primária reproduzível →
  UNVERIFIED até vincular URL exata.

## 1. Claims upstream verificadas (AC1)

| # | Claim | Verificação (doc primária exata + trecho/parâmetro) | Data / versão |
|---|---|---|---|
| M1 | MXC: SDKs Rust / NuGet / npm, licença MIT, repo `microsoft/mxc` | `https://github.com/microsoft/mxc` (repo; manifestos/licença no checkout `main` out-2026 — commit exato UNVERIFIED) | vigente out-2026 |
| M2 | Contrato policy 1.0.0 com schema fechado | `https://github.com/microsoft/mxc/blob/main/docs/containment-policy/1.0.0/policy.md` (contrato 1.0.0, schema) | 1.0.0 |
| M3 | GA Win11 + Win365 | `https://blogs.windows.com/windowsdeveloper/2026/10/07/microsoft-execution-containers-policy-driven-containment-for-ai-agents/` (anúncio GA) | 07-out-2026 |
| M4 | `windows_sandbox` / `microvm` / `hyperlight` **experimentais e NÃO aceitos em 1.0.0**; aceitos só `process`, `processcontainer`, `lxc`, `bubblewrap`, `seatbelt`, `isolation_session`, `wslc` | `https://github.com/microsoft/mxc/blob/main/docs/containment-policy/1.0.0/policy.md` (lista `backends` suportados) | 1.0.0 |
| M5 | Intune "soon", Entra "coming soon" (não GA) | Anúncio GA acima (menção roadmap) — trecho/parâmetro exato não vinculado → **UNVERIFIED** até citar seção/parágrafo | out-2026 UNVERIFIED |
| M6 | Defaults deny: network omitido / egress / ingress / hostLoopback = deny; deny vence allow; só CIDR + ports, sem hostname | `https://github.com/microsoft/mxc/blob/main/docs/containment-policy/1.0.0/policy.md` (seção `network`: defaults deny, precedência deny-sobre-allow, `cidr` + `ports`, sem hostname-allow) | 1.0.0 |
| M7 | Proxy caller-managed cooperativo (não é barreira de segurança sozinho) | `https://github.com/microsoft/mxc/blob/main/docs/containment-policy/1.0.0/policy.md` (seção proxy caller-managed) | 1.0.0 |
| M8 | FS `readwrite` / `readonly` / `denied`; `denied` **não suportado no Windows** | `https://github.com/microsoft/mxc/blob/main/docs/containment-policy/1.0.0/policy.md` (seção `filesystem`: enum + nota Windows) | 1.0.0 |
| M9 | Credenciais via env — MXC **não é vault** | `https://github.com/microsoft/mxc/blob/main/docs/containment-policy/1.0.0/policy.md` (seção credentials/env) — seção exata não vinculada → **PARCIAL/UNVERIFIED** até citar âncora | 1.0.0 UNVERIFIED (âncora) |
| M10 | MCP stdio filho de Pi: fora de MXC salvo harness-in-MXC (Pi-in-MXC) | `https://github.com/microsoft/mxc/blob/main/docs/logging-access-denied.md` + `policy.md` (spawn/child fora do boundary salvo harness) — vínculo de spawn-via-MXC não provado aqui → **UNVERIFIED** até probe | 1.0.0 UNVERIFIED (probe pendente) |
| M11 | Fail-closed positivo (rejeita `unsupported`) **mas** furos reais: `--audit` desliga enforcement; `permissiveLearningMode` / `captureDenials: allow` = allow-all; #1455 powershell PATH monta `C:` readonly | Primária: `policy.md` + `logging-access-denied.md` (rejeita `unsupported`; flags `--audit` / `permissiveLearningMode` / `captureDenials`). Secundária separada (NÃO evidência): `https://cruxdigits.nl/blog/microsoft-execution-containers-evidence/` (**SECUNDÁRIA**) e #1455 sem URL primária → **UNVERIFIED** até probe no binário pinado | out-2026; #1455 UNVERIFIED |
| M12 | Requisitos: Win11 / Linux / macOS, Rust 1.93, Node 24 | `https://github.com/microsoft/mxc` (docs de requisitos no `main` out-2026) — página exata não vinculada → **UNVERIFIED** até citar path/âncora | out-2026 UNVERIFIED |
| P1 | Pi 1.1 estável: OSC 7501 `working` / `blocked` / `done` / `error` / `idle`; `aborted` em `agent_settled`; `durationMs`; lifecycle; abort Esc / 15 s | `https://pi.dev/changelog/releases/1.1.0` + `https://pi.dev/docs/latest/terminal-setup#program-status` (status OSC 7501, lifecycle, abort) | 05-out-2026 |
| P2 | Telemetria via `pi-otel` / `pi-trace`; core sem phone-home; creds fora da telemetria | `https://pi.dev/docs/latest/extensions` + `https://pi.dev/docs/latest/security` (extensões `pi-otel`/`pi-trace`; sem phone-home; creds) — doc corrente `latest` mutável, NÃO versionada → **UNVERIFIED** para 1.1.0 até vincular trecho versionado; só `https://pi.dev/changelog/releases/1.1.0` é evidência versionada 1.1.0 | 1.1.0 UNVERIFIED (trecho versionado pendente) |
| P3 | MXC telemetry opt-in em 4 camadas | `https://github.com/microsoft/mxc/blob/main/docs/containment-policy/1.0.0/policy.md` (seção telemetry opt-in) — âncora exata não vinculada → **PARCIAL/UNVERIFIED** | 1.0.0 UNVERIFIED (âncora) |
| P4 | Classificadores locais `llama.cpp >= 0.6.0` SystemOne (Julia-1 / Laya / Kev / lev / OpenJev) + nuvem Jev / Clef / Luna | `https://pi.dev/docs/latest/models#use-classifier-models` + `https://pi.dev/docs/latest/llama-cpp#classification` (versão `>= 0.6.0`, nomes SystemOne) — nomes de modelos não vinculados a trecho exato → **PARCIAL/UNVERIFIED** até citar trecho | 1.1.0 UNVERIFIED (trecho) |

## 2. Threat model (AC2)

**Ativos:** credenciais do operador, filesystem do checkout, rede local/LAN,
capacidade de spawn de processos/MCP.

**Atores:** extensão Pi maliciosa ou comprometida; tool MCP remota;
configuração de policy errada (allow amplo); operador em modo authoring.

**Vetores e controles:**

1. **Egress não autorizado** → default deny MXC (M6); sem hostname-allow
   (bypass DNS fora do modelo — não confiar em filtro por nome).
2. **Exfiltração via proxy cooperativo** → proxy NÃO é barreira única
   (M7, REJECT §5); exigir enforcement no backend, não no caller.
3. **`--audit` / `permissiveLearningMode` / `captureDenials: allow`** →
   equivalem a allow-all (M11); banidos em prod via grep gate (§6).
4. **Powershell PATH montando `C:` readonly (#1455)** → tratar mount
   implícito como superfície auditável; revalidar no runtime exato.
5. **`denied` sem efeito no Windows** → no Windows, `denied` é
   apenas evidência `record-only`, não enforcement (M8); capacidade de negar
   leitura em **HOLD — gap bloqueante** até comprovar por probe no runtime
   exato a negação efetiva de leitura (exclusão/inacessibilidade) no backend
   escolhido; `readonly` e mero registro `record-only` **NÃO** são saída do
   HOLD; sem alternativa presumida.
6. **Credenciais via env** → MXC não é vault (M9); segredos continuam via
   env do runtime, nunca em policy/logs/telemetria.
7. **MCP stdio filho fora de MXC** → sem harness-in-MXC não há isolamento
   (M10); MCP child = HOLD até spawn-via-MXC provado.
8. **MicroVM / Hyperlight / Sandbox experimentais** → fora do contrato
   1.0.0 (M4); ban em prod até estabilidade + revalidação.

## 3. Matriz de compatibilidade (AC2)

| Capacidade | Windows | Linux | macOS | Veredito |
|---|---|---|---|---|
| Isolar tool (Pi-in-MXC) | OK (process/processcontainer) | OK (bubblewrap/lxc) | OK (seatbelt) | **OK** |
| Fail-closed (rejeita unsupported) | OK | OK | OK | **OK** |
| Evidence de deny (`denied`) | `denied` **não suportado** → record-only | OK | gap a provar | **PARCIAL** |
| MCP child isolado | HOLD (só via spawn MXC provado) | HOLD | HOLD | **HOLD** |
| duration / abort (Pi 1.1) | OK | OK | OK | **ADOPT-ready** |
| Classificadores locais (llama.cpp) | OK | OK | OK | **OK** |

## 4. Benefício mensurável / decisão (AC3)

**ADOPT parcial Pi 1.1** (eventos + telemetria read-only, sem wiring novo):

- `aborted` em `agent_settled` + `durationMs` → latência/abort por sessão
  mensuráveis hoje (OSC 7501, lifecycle, abort Esc/15 s).
- `tool_end` + `pi-otel` / `pi-trace` → taxa de deny/bloqueio observável sem
  enforcement.
- Classificadores locais `llama.cpp >= 0.6.0` → inferência local sem
  dependência de nuvem (Jev/Clef/Luna continuam opt-in).

**HOLD MXC** — gates de saída (todos, sem exceção):

1. Pin 1.0.0 registrado em `source/registry/runtime-versions.json`.
2. Backends permitidos **apenas** `processcontainer` (Win) / `bubblewrap`
   (Linux); ban `microvm` / `hyperlight` / `sandbox`.
3. Ban em prod via grep gate: `--audit`, `permissiveLearningMode`,
   `captureDenials: allow`, `profileOverride` sem review.
4. Wiring MCP-child (spawn-via-MXC) provado no runtime exato.
5. Negação de leitura no Windows comprovada por probe no runtime exato
   (exclusão/inacessibilidade efetiva no backend escolhido; `readonly` e
   mero `record-only` documentado **NÃO** são saída; gap Linux/macOS
   fechado por probe).
6. Policy versionada sob review.
7. Reavaliar com Intune/Entra GA + MicroVM estável.

## 5. Rejeição explícita (AC3)

- **REJECT** `--audit` em prod (desliga enforcement).
- **REJECT** `captureDenials: allow` fora de authoring (allow-all).
- **REJECT** `profileOverride` sem review humano.
- **REJECT** proxy caller-managed como única barreira (cooperativo, M7).
- **REJECT** backends experimentais em prod (`microvm`, `hyperlight`,
  `windows_sandbox`) até contrato 1.0.0 cobri-los.

## 6. Sem dependência prod por padrão (AC4)

- Nenhum backend MXC em prod; nenhum pin/flag/enforcement novo neste ADR.
- Pi 1.1: somente consumo read-only de eventos (`working`/`blocked`/`done`/
  `error`/`idle`, `aborted`, `durationMs`) e telemetria `pi-otel`/`pi-trace`.
- Nenhum wiring MCP novo; nenhum spawn via MXC; nenhuma credencial nova.
- Gaps que exigem **probe em runtime exato antes de qualquer código**:
  comportamento `denied` no Windows, gap Linux/macOS, mount implícito
  powershell PATH (#1455), semântica real de `captureDenials` e
  `permissiveLearningMode` no binário pinado.

## 7. Referências (primária versionada 1.1.0 + docs correntes `latest` mutáveis; secundária separada)

- `https://github.com/microsoft/mxc` (`main` vigente out-2026; commit exato UNVERIFIED)
- `https://blogs.windows.com/windowsdeveloper/2026/10/07/microsoft-execution-containers-policy-driven-containment-for-ai-agents/` — anúncio GA (07-out-2026)
- MXC `https://github.com/microsoft/mxc/blob/main/docs/containment-policy/1.0.0/policy.md` (contrato 1.0.0)
- MXC `https://github.com/microsoft/mxc/blob/main/docs/logging-access-denied.md`
- `https://pi.dev/changelog/releases/1.1.0` (05-out-2026) — única ref Pi versionada (1.1.0)
- `https://pi.dev/docs/latest/terminal-setup#program-status` (doc corrente `latest`, mutável — NÃO versionada; contexto apenas)
- `https://pi.dev/docs/latest/models#use-classifier-models` (doc corrente `latest`, mutável — NÃO versionada; contexto apenas)
- `https://pi.dev/docs/latest/llama-cpp#classification` (doc corrente `latest`, mutável — NÃO versionada; contexto apenas)
- `https://pi.dev/docs/latest/security` (doc corrente `latest`, mutável — NÃO versionada; contexto apenas)
- `https://pi.dev/docs/latest/extensions` (doc corrente `latest`, mutável — NÃO versionada; contexto apenas)
- Secundária (NÃO evidência primária): `https://cruxdigits.nl/blog/microsoft-execution-containers-evidence/` (SECUNDÁRIA); HN #1455 sem URL primária reproduzível → UNVERIFIED

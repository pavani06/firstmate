# PATCHES — divergências deste fork vs upstream

Fork de `kunchenguid/firstmate`. Política: patches mínimos e
upstreamáveis; rebase com upstream só por decisão explícita do captain
registrada; cada patch abaixo é exercitado por um teste da suíte
EXP-MF-003/004 (docs no repo `pavani06/govevo`).

Base da branch `exp-mf-004`: upstream `a09090d1` (2026-09-20), o mesmo pin
verificado no EXP-MF-003. O `main` do fork (`8d2fabed`, sync de 2026-09-21)
não é a base do experimento.

| Patch | Arquivos | O que muda | Lacuna que fecha | Problema documentado upstream |
|---|---|---|---|---|
| P1 | `bin/fm-spawn.sh`, `bin/fm-worker-sandbox.sh` (novo) | `config/worker-launch-wrapper` (caminho absoluto, uma linha) envolve o launch de pi/pi-signed com um sandbox bwrap: namespaces PID/IPC/UTS, HOME tmpfs, `/run/user` mascarado, whitelist de binds rw, `SSH_AUTH_SOCK` removido, `GH_TOKEN` de instalação da App por dispatch (mint via gh-token + PEM SOPS), identidade git do worker, `PI_CODING_AGENT_DIR` = cópia por dispatch | F3/F4 (no ambient credentials; write fora do workspace) | issue #3742 (closed) introduziu o launch-env-allowlist; o wrapper é o complemento de filesystem/processo que ele não cobre |
| P2 | `bin/fm-crew-state.sh` | Veredito `idle` também consulta o classificador `fm_backend_agent_state`; `dead/missing` → "agent process gone" em vez do fallback para o status log | F6(ii), F11 (ressurreição de mortos) | #3545, #3402 |
| P3 | `bin/fm-control.sh`, `bin/fm-classify-lib.sh` | `fm-control exit` apenda `stopped [at=<epoch>]: exit by captain` ao `.status`; `stopped` é verbo reconhecido, terminal, captain-relevant. Primeira exceção ao contrato "só o worker escreve o status" — declarada no patch | F7 | — |
| P4 | `AGENTS.md` §7 | Intake cria o item de backlog (`bin/fm-tasks-axi.sh add`); teardown já o fecha | F12 (elo backlog) | — |

## Evidência de origem

EXP-MF-003 (baseline): `pavani06/govevo` →
`docs/evidence/experiments/firstmate/2026-09-20-exp-mf-003.md`;
protocolo `docs/master-plan/exp-mf-003-f-suite-protocol.md`; plano de
remediação `docs/master-plan/exp-mf-004-remediation-plan.md`.

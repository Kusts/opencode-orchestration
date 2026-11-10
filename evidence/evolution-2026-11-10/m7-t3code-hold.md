# M7 — T3 Code (piloto externo) — HOLD

**Data:** 2026-11-10
**Status:** HOLD — não iniciado

## Motivo

O M7 é um piloto de um produto externo (T3 Code) como console web/mobile do
OpenCode V2. Ele exige:

1. disponibilidade do produto/credenciais do operador;
2. um projeto descartável para a ação controlada;
3. confirmação de que o Task Kernel continua responsável pelas conclusões.

Nada disso foi executado nesta rodada. Não há código a implementar antes do
piloto; criar um console próprio contradiz o não-objetivo explícito.

## Critério de entrada

- produto acessível e autenticado;
- sessão de leitura funcionando;
- projeto descartável identificado;
- janela para uma ação controlada e reversível.

## Critério de saída

Acompanhar uma sessão e continuar uma interação remotamente sem instalar outro
mecanismo de orquestração. Se não atender, registrar o resultado e encerrar o
piloto.

## Decisão

Mantido em HOLD até o operador fornecer acesso ao produto. Nenhuma dependência
do pacote foi alterada.

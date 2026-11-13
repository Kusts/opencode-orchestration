# M6 ingress signature (#183)

The reusable verifier checks GitHub `X-Hub-Signature-256` as HMAC-SHA256 over exact body bytes. The intake can opt in using `-SecretFile` or `-SecretEnvVar` together with `-SignatureHeader`; verification happens before JSON parsing or ledger writes. Without a configured secret, legacy behavior remains and output states `signature_status=not-configured`. With a secret, missing or invalid signatures fail closed.

Secret files are UTF-8, trimmed, limited to 4096 bytes by default, and reject missing, empty, UNC, directories and reparse paths. The standalone CLI reads raw bodies up to 1 MiB. Intake's existing envelope cap remains 64 KiB. Errors do not disclose secret or expected MAC. The standalone CLI returns compact JSON with body byte count and SHA-256 digest.

This is not an operational HTTP receiver or authenticated end-to-end ingestion. Secret rotation, replay/`issued_at` validation, durable ledger operations, and a real producer/receiver remain out of scope. No production credentials, network, or webhook were used.

Validation: `OrchestrationEventSignature.tests.ps1` passed 27 assertions in Windows PowerShell 5.1 and pwsh. The 7 `OrchestrationEvent*` suites passed in both runtimes; intake 13/13, bridge 9/9, correlation 11/11, signature 27 assertions, and slow path 146 assertions. `test-package-consistency.ps1` passed 17/17; CLI fixture returned exits 0/1/2 and stable body digest `230d8358dc8e8890b4c58deeb62912ee2f20357ae92a5cc861b98e68fe31acb5`; no secret appeared in CLI output. `git diff --check` was clean.

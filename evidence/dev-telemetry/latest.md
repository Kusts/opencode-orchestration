# dev-telemetry

generated_at: 2026-10-22T00:02:29.4212155+00:00 | window_days: 30

## resumo

| metrica | valor |
| --- | --- |
| events | 80 |
| files | 2 |
| first_ts | 2026-10-21T12:00:00.0000000+00:00 |
| last_ts | 2026-10-22T00:01:46.2746766+00:00 |
| suite_runs | 54 |
| pass | 41 |
| fail | 3 |
| skip | 10 |
| error | 0 |
| pass_rate | 0.9318 |

## suites com falha

| suite | runs | pass | fail | skip | error | pass_rate |
| --- | --- | --- | --- | --- | --- | --- |
| DevTelemetry.tests | 29 | 18 | 2 | 9 | 0 | 0.9 |
| skills-catalog.tests | 1 | 0 | 1 | 0 | 0 | 0 |

## 5 mais lentas (p95_ms)

| suite | p95_ms | p50_ms | runs |
| --- | --- | --- | --- |
| eol-checkout.tests | 40125 | 40125 | 1 |
| capability-routing-phase2d.tests | 35055 | 35055 | 1 |
| runtime-install.tests | 30633 | 30633 | 1 |
| profile-isolation.tests | 24805 | 24805 | 1 |
| config-format.tests | 23424 | 23424 | 1 |

## flaky (FAIL/ERROR -> PASS)

| suite | from | to | from_ts | to_ts |
| --- | --- | --- | --- | --- |
| DevTelemetry.tests | FAIL | PASS | 2026-10-21T23:57:52.9018202+00:00 | 2026-10-21T23:58:20.7773432+00:00 |

## preflight

| total | 5 |
| fallback_rate | 0.4 |

| decision | count |
| --- | --- |
| DETERMINISTIC_FALLBACK | 2 |
| MULTI_WORKER | 2 |
| SINGLE_WORKER | 1 |

## plugin

| metrica | valor |
| --- | --- |
| reports | 0 |
| latest_overall |  |
| latest_load_errors | 0 |
| latest_expected_load_errors | 0 |
| latest_telemetry_present | 0 |

## review

| metrica | valor |
| --- | --- |
| total | 6 |
| approved | 6 |
| changes_required | 0 |

## gates

| metrica | valor |
| --- | --- |
| reports | 15 |
| pass | 13 |
| fail | 2 |
| checks_total | 240 |
| checks_fail | 2 |

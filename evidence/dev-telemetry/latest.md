# dev-telemetry

generated_at: 2026-10-22T00:28:34.2481094+00:00 | window_days: 30

## resumo

| metrica | valor |
| --- | --- |
| events | 94 |
| files | 2 |
| first_ts | 2026-10-21T12:00:00.0000000+00:00 |
| last_ts | 2026-10-22T00:28:28.5190070+00:00 |
| suite_runs | 63 |
| pass | 48 |
| fail | 5 |
| skip | 10 |
| error | 0 |
| pass_rate | 0.9057 |

## suites com falha

| suite | runs | pass | fail | skip | error | pass_rate |
| --- | --- | --- | --- | --- | --- | --- |
| DevTelemetry.tests | 38 | 25 | 4 | 9 | 0 | 0.8621 |
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
| DevTelemetry.tests | FAIL | PASS | 2026-10-22T00:24:15.6423124+00:00 | 2026-10-22T00:24:50.6976748+00:00 |

## preflight

| total | 7 |
| fallback_rate | 0.2857 |

| decision | count |
| --- | --- |
| DETERMINISTIC_FALLBACK | 2 |
| MULTI_WORKER | 4 |
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
| total | 7 |
| approved | 7 |
| changes_required | 0 |
| high_or_critical | 0 |

### by source
| valor | count |
| --- | ---: |
| planner | 6 |
| reviewer | 1 |

### by severity
| valor | count |
| --- | ---: |
| NONE | 1 |
| UNSPECIFIED | 6 |

## gates

| metrica | valor |
| --- | --- |
| reports | 17 |
| pass | 14 |
| fail | 3 |
| checks_total | 272 |
| checks_fail | 3 |

# Performance benchmarking

Record one immutable workload descriptor before the first run: actual user config (or an explicitly marked synthetic representative, distinct from the requested target), hash/version, seed/RNG state, session and worker counts, and environment. Runs with different workloads are not comparable.

Run a short baseline before a long run. Compare only equivalent conditions: same workload descriptor, cold or steady state, semantic output. Small parallel runs only project a larger run; report measured and projected figures separately.

Keep these pairs distinct: production vs test workloads, cold vs steady state, sampled allocation vs resident set size, CPU vs wall time, measured vs projected. A growth or leak claim needs an early/late profile pair.

Boot/loading lots: the brief's Known state traces the wait chain (user-unblocking event → awaited promises → loaders, with paths); reordering assets never moves a load awaited by another route.

Preserve RNG and math behavior unless scope changes. To test concurrency effects, compare same-seed isolated and concurrent runs.

Stop when no measured hypothesis remains open for the scoped workload; never claim an absolute maximum. After an ambiguous failure, recover the known run ID before relaunching; a launch intent is persisted per run and is never silently repeated. Give each expensive measurement one owner; run once and reuse the result.

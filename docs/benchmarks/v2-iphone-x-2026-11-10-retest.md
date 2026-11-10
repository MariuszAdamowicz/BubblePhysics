# BubblePhysics 2.0 — ponowny pomiar acceptance na iPhonie X

- Data: 2026-11-10; iPhone X, iOS 16.7.16; Xcode 26.6, konfiguracja Release.
- Mierzony kod: `a367bd0567f01d4ccf142691958c53e6249e8d3f`, gałąź `feature/engine-foundations`.
- Poprzednią aplikację odinstalowano przed instalacją nowego buildu. Surowy raport skopiowany z aplikacji przez właściciela:

```text
path=public BubbleWorld + BubblePhysicsMetalRender, same command buffer
device=Apple A11 GPU
scene=acceptance; solver_iteration_limit=4
render_px=1125x2436
warmup=30; measured=300
p95_ms=24.2744; max_ms=25.4957
gpu_p95_ms=14.7964; host_non_gpu_p95_ms=9.6007
host_encoding_p95_ms=1.9882; host_waiting_p95_ms=15.8875
guard_corrections=0; non_finite_frames=0
fallback_frames=0; failed_frames=0
contour_cpu_readbacks=0
contact_candidate_overflow=0; max_candidates_per_object=32; candidate_limit=128
safety=pass
native_quality_envelope=not_evaluated_by_this_harness
p95_gate_ms=16.6700; p95_gate=fail
```

P95 pełnej klatki przekracza próg o 7,6044 ms: bramka wydajności nie jest spełniona. Nie wystąpiły błędne klatki, wartości non-finite, fallbacki, odczyty konturów na CPU ani przepełnienia kandydatów. Maksimum 32 kandydatów mieści się w połowie limitu 128. Harness nie ocenił `native_quality_envelope`.

Wcześniejszy [pomiar](v2-iphone-x-2026-11-10.md) używał rozdzielczości `960x1440`; różnica rozdzielczości wyklucza bezpośrednie porównanie czasów jako oceny zmiany wydajności.

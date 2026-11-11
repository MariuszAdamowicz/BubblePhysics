# BubblePhysics 2.0 — pomiar pojemności na iPhonie X

- Data: 2026-11-11; iPhone X, iOS 16.7.16; Xcode 26.6, konfiguracja Release.
- Mierzony commit: `e40add5bdc4f7031f65127ea62538f116b0738c2` (`feature/engine-foundations`).
- Poprzednią aplikację odinstalowano przed instalacją nowego buildu. Surowy raport skopiowany z aplikacji przez właściciela:

```text
path=public BubbleWorld + BubblePhysicsMetalRender, same command buffer
device=Apple A11 GPU
scene=capacity
warmup=30; measured=300
p95_gate_ms=16.6700
level=100; cooldown_s=0.0; cooldown_timeout=0; thermal_worst=nominal; valid=1; p95_ms=11.7711; host_non_gpu_p95_ms=4.4515; gpu_physics_p95_ms=4.9972; gpu_render_estimate_ms=2.6315; max_candidates_per_object=35; candidate_limit=128; failed_frames=0; non_finite_frames=0; contour_cpu_readbacks=0; contact_candidate_overflow=0; bubbles=100
level=150; cooldown_s=0.0; cooldown_timeout=0; thermal_worst=nominal; valid=1; p95_ms=14.3806; host_non_gpu_p95_ms=4.8568; gpu_physics_p95_ms=5.8030; gpu_render_estimate_ms=4.1467; max_candidates_per_object=32; candidate_limit=128; failed_frames=0; non_finite_frames=0; contour_cpu_readbacks=0; contact_candidate_overflow=0; bubbles=150
level=200; cooldown_s=0.0; cooldown_timeout=0; thermal_worst=nominal; valid=1; p95_ms=17.3360; host_non_gpu_p95_ms=5.8551; gpu_physics_p95_ms=6.4482; gpu_render_estimate_ms=5.4154; max_candidates_per_object=32; candidate_limit=128; failed_frames=0; non_finite_frames=0; contour_cpu_readbacks=0; contact_candidate_overflow=0; bubbles=200
level=250; cooldown_s=0.0; cooldown_timeout=0; thermal_worst=nominal; valid=1; p95_ms=20.1573; host_non_gpu_p95_ms=6.4212; gpu_physics_p95_ms=7.3560; gpu_render_estimate_ms=6.5953; max_candidates_per_object=35; candidate_limit=128; failed_frames=0; non_finite_frames=0; contour_cpu_readbacks=0; contact_candidate_overflow=0; bubbles=250
level=300; cooldown_s=0.0; cooldown_timeout=0; thermal_worst=nominal; valid=1; p95_ms=23.2560; host_non_gpu_p95_ms=7.2673; gpu_physics_p95_ms=8.1536; gpu_render_estimate_ms=8.1302; max_candidates_per_object=32; candidate_limit=128; failed_frames=0; non_finite_frames=0; contour_cpu_readbacks=0; contact_candidate_overflow=0; bubbles=300
level=350; cooldown_s=0.0; cooldown_timeout=0; thermal_worst=nominal; valid=1; p95_ms=26.3655; host_non_gpu_p95_ms=8.2646; gpu_physics_p95_ms=9.1049; gpu_render_estimate_ms=9.3670; max_candidates_per_object=37; candidate_limit=128; failed_frames=0; non_finite_frames=0; contour_cpu_readbacks=0; contact_candidate_overflow=0; bubbles=350
level=400; cooldown_s=0.0; cooldown_timeout=0; thermal_worst=nominal; valid=1; p95_ms=29.3515; host_non_gpu_p95_ms=9.0695; gpu_physics_p95_ms=10.1457; gpu_render_estimate_ms=10.6097; max_candidates_per_object=36; candidate_limit=128; failed_frames=0; non_finite_frames=0; contour_cpu_readbacks=0; contact_candidate_overflow=0; bubbles=400
capacity=150
```

Pojemność w tym scenariuszu i przy badanych poziomach wynosi 150 baniek: p95 `14,3806 ms` przy 150, a `17,3360 ms` przy następnym poziomie 200, wobec progu `16,67 ms`. Wszystkie poziomy mają `valid=1`, nominalny stan termiczny, zgodną liczbę baniek i zerowe liczniki błędów, wartości non-finite, odczytów konturów CPU oraz przepełnień kandydatów. Największa liczba kandydatów na obiekt to 37 z limitu 128.

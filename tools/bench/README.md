# bench

The first benchmark lives at:

```text
apps/app/test/reader_100_page_benchmark_test.dart
```

It records two deterministic baselines:

- parse a 100-page local manifest;
- produce 100 heuristic role windows and demand plans.

It intentionally does not claim raster/decode performance. Device integration benchmarks are added after Android scaffolding and real session lanes exist.

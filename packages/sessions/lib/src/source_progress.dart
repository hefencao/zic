/// Shared production threshold for encoded-source growth scheduling and
/// committed-byte telemetry. Keeping both decisions on one boundary prevents
/// transport chunk sizes from becoming decode or diagnostics policy.
const int sourceProgressQuantumBytes = 64 * 1024;

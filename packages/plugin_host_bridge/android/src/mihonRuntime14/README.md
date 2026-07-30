# Mihon 1.4 runtime compatibility

This source set supplies runtime implementations for the throwing compile-only
classes in Keiyoushi `extensions-lib` 1.4. Its public behavior and JVM shapes
are based on Mihon's Apache-2.0-licensed `source-api` and `core/common`
implementations immediately before the TachiyomiX 1.6 migrations
(`4c37f4c76^`, `430b13bb8^`, and `94cab02c1^`).

The Gradle asset task compiles these sources in isolation, removes the matching
stub classes from `extensions-lib`, and D8-compiles one versioned ABI asset.
They are deliberately not part of the application classpath.

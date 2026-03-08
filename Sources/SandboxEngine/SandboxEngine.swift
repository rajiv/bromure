// SandboxEngine umbrella — re-exports for convenience.
// All public types are defined in their own files:
//   - VMConfig.swift          — configuration and metadata types
//   - BaseImageManager.swift  — golden base image creation
//   - EphemeralDisk.swift     — APFS CoW clone management
//   - SandboxVM.swift         — VM lifecycle
//   - SandboxWindowController.swift — GUI display
//   - SandboxError.swift      — error types

/// Escape a string for safe inclusion in a single-quoted shell argument.
/// Replaces each `'` with `'\''` (end quote, escaped quote, reopen quote).
public func shellEscape(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

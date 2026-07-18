# Phosphor Product Polish and Readiness Center Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Turn the broad “make Phosphor better” roadmap into shippable vertical slices, starting with a centralized Readiness Center that improves onboarding, Wi‑Fi/device clarity, diagnostics, safe-operation guidance, and UI task organization.

**Architecture:** Add a small `ReadinessService` that produces a value-type report independent of SwiftUI. Surface it through `DeviceViewModel` and a new `ReadinessCenterView` reachable from the sidebar and welcome screen. Keep behavior testable with repo-local regression checks before broadening into deeper Messages, archive safety, and release polish follow-ups.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, repo-local Python regression runner under `Scripts/regression`.

---

## Phase 1: Readiness Center vertical slice

### Task 1: Add regression checks first

**Objective:** Protect the new architecture before implementation.

**Files:**
- Create: `Scripts/regression/checks/readiness_center.py`
- Test command: `Scripts/regression/run.py`

**Checks:**
- `ReadinessService.swift` exists and exposes `ReadinessReport`, `ReadinessItem`, `ReadinessStatus`, and `ReadinessService.evaluate`.
- `ReadinessService` uses `Task.detached` for dependency probing instead of wrapping `Shell.checkDependencies()` in `DispatchQueue.global()` from UI code.
- `DeviceManager.checkDependencies`, `WelcomeView`, and `OnboardingView` no longer directly call `DispatchQueue.global()` for dependency checks.
- `SidebarSection` contains a `readiness` case with a visible sidebar row.
- `ReadinessCenterView.swift` exists and contains explicit copy for tool readiness, backup folder readiness, Wi‑Fi/Finder visibility, safe operations, diagnostics export, and next steps.

### Task 2: Implement `ReadinessService`

**Objective:** Centralize tool, backup-folder, Wi‑Fi visibility, and diagnostic summary generation.

**Files:**
- Create: `Sources/Phosphor/Services/ReadinessService.swift`
- Modify: `Sources/Phosphor/Services/DeviceManager.swift`
- Modify: `Sources/Phosphor/ViewModels/DeviceViewModel.swift`

**Details:**
- Add `ReadinessStatus` enum: `.ready`, `.warning`, `.blocked`, `.info`.
- Add `ReadinessItem` with `title`, `detail`, `status`, `recoveryAction`, and `technicalDetail`.
- Add `ReadinessReport` with `generatedAt`, `items`, computed `hasBlockers`, `hasWarnings`, `summary`, and markdown diagnostic export.
- `ReadinessService.evaluate(devices:nearbyWirelessDevices:backupDirectory:)` should:
  - check dependencies off-main via `Task.detached { Shell.checkDependencies() }.value`;
  - validate backup directory with `BackupManager.validateBackupDirectory`;
  - include backup-directory cloud warnings;
  - distinguish USB/Wi‑Fi backup-capable devices, Finder/Bonjour-visible nearby devices, and no visible devices;
  - explain first-time Wi‑Fi backup requirements;
  - summarize safe operations and diagnostic export behavior.
- Replace ad-hoc `DispatchQueue.global()` dependency checks with `ReadinessService.dependencyStatus()`.

### Task 3: Add Readiness Center UI

**Objective:** Give users one place to understand whether Phosphor is ready and what to do next.

**Files:**
- Create: `Sources/Phosphor/Views/Readiness/ReadinessCenterView.swift`
- Modify: `Sources/Phosphor/Views/SidebarView.swift`
- Modify: `Sources/Phosphor/Views/ContentView.swift`

**Details:**
- Add sidebar section `Readiness` near the Device group.
- Display summary cards for tool readiness, backup folder, device visibility, Wi‑Fi backup state, safe operations, and diagnostic export.
- Add Refresh button using `DeviceViewModel.refreshReadiness()`.
- Add Export Diagnostic Report button that writes a timestamped redacted Markdown report to the user-selected folder or Desktop fallback.
- Add `Open Backup Settings` action guidance by text for now; do not introduce cross-view navigation coupling in this slice.

### Task 4: Update onboarding and welcome paths

**Objective:** Remove duplicate dependency-check code and make first-run guidance point to Readiness Center.

**Files:**
- Modify: `Sources/Phosphor/Views/Onboarding/OnboardingView.swift`
- Modify: `Sources/Phosphor/Views/ContentView.swift`

**Details:**
- Use `ReadinessService.dependencyStatus()` rather than manual `DispatchQueue.global()` continuations.
- In `WelcomeView`, replace duplicated dependency rows with a short “Run Readiness Check” call-to-action and compact dependency status text.
- Keep first paint fast; do not run expensive work synchronously on view init.

### Task 5: Verify and commit

**Objective:** Prove the vertical slice works without claiming unrun checks.

**Commands:**
- `Scripts/regression/run.py`
- `swift build`
- `swift build -c release`
- `bash Scripts/build.sh`

**Commit:**
- `feat: add readiness center and diagnostics guidance`

---

## Phase 2: Safe operations hardening

Follow-up branch after Phase 1 or after current stability PR lands.

- Add shared destination/collision policy for exports/imports.
- Add archive import staging and path traversal regression fixtures.
- Add destructive-action preview summaries.
- Add Finder reveal/open result affordances for completed exports.

---

## Phase 3: Messages flagship polish

Follow-up branch after Phase 1.

- Expand message readiness taxonomy coverage.
- Add export preview counts and filter summaries.
- Strengthen CSV/MBOX/HTML fixtures with parsed assertions.
- Make long export progress/cancel paths fully behavioral-tested.

---

## Phase 4: Backup browsing polish

Follow-up branch after Phase 1.

- Add visible scan progress and cancel where expensive.
- Add clearer large-backup lazy size copy.
- Add quick filters for common restore/extract targets.

---

## Phase 5: Distribution/release trust

Follow-up branch after Phase 1.

- Keep in-app version, Info.plist, changelog, and Homebrew tap release notes aligned.
- Add a release checklist document.
- Investigate signed/notarized distribution only after maintainer approval.

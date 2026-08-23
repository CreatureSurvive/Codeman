import Foundation

/// The SSE event registry, mirrored from `src/web/sse-events.ts` (155 constants).
///
/// `SSEEventNameParityTests` reads that TypeScript file at test time and asserts this list is
/// exactly equal, so a server-side addition fails the native suite instead of silently becoming
/// an ignored event.
///
/// Decoding never fails: an unrecognised name becomes `.unknown(String)` and is dropped by the
/// dispatcher without error, so a newer server cannot break an older client.
enum SSEEventName: RawRepresentable, Sendable, Hashable {
    case known(Known)
    case unknown(String)

    /// Every registered event name. Raw values are the wire strings.
    enum Known: String, Sendable, Hashable, CaseIterable {
        // Core
        case initial = "init"

        // Transport
        case heartbeat = "sse:heartbeat"

        // Session lifecycle
        case sessionCreated = "session:created"
        case sessionUpdated = "session:updated"
        case sessionDeleted = "session:deleted"
        case sessionTerminal = "session:terminal"
        case sessionNeedsRefresh = "session:needsRefresh"
        case sessionClearTerminal = "session:clearTerminal"
        case sessionCompletion = "session:completion"
        case sessionError = "session:error"
        case sessionExit = "session:exit"
        case sessionIdle = "session:idle"
        case sessionWorking = "session:working"
        case sessionAutoClear = "session:autoClear"
        case sessionAutoCompact = "session:autoCompact"
        case sessionLimitPauseScheduled = "session:limitPauseScheduled"
        case sessionLimitResume = "session:limitResume"
        case sessionLimitResumeCancelled = "session:limitResumeCancelled"
        case sessionRespawnBreakerTripped = "session:respawnBreakerTripped"
        case sessionCliInfo = "session:cliInfo"
        case sessionPinned = "session:pinned"
        case sessionMessage = "session:message"
        case sessionInteractive = "session:interactive"
        case sessionRunning = "session:running"
        case sessionStatusTelemetry = "session:statusTelemetry"

        // Session: Ralph
        case sessionRalphLoopUpdate = "session:ralphLoopUpdate"
        case sessionRalphTodoUpdate = "session:ralphTodoUpdate"
        case sessionRalphCompletionDetected = "session:ralphCompletionDetected"
        case sessionRalphStatusUpdate = "session:ralphStatusUpdate"
        case sessionCircuitBreakerUpdate = "session:circuitBreakerUpdate"
        case sessionExitGateMet = "session:exitGateMet"

        // Session: Bash tools
        case sessionBashToolStart = "session:bashToolStart"
        case sessionBashToolEnd = "session:bashToolEnd"
        case sessionBashToolsUpdate = "session:bashToolsUpdate"

        // Session: Plan
        case sessionPlanTaskUpdate = "session:planTaskUpdate"
        case sessionPlanCheckpoint = "session:planCheckpoint"
        case sessionPlanRollback = "session:planRollback"
        case sessionPlanTaskAdded = "session:planTaskAdded"

        // Tasks
        case taskCreated = "task:created"
        case taskCompleted = "task:completed"
        case taskFailed = "task:failed"
        case taskUpdated = "task:updated"

        // Mux
        case muxCreated = "mux:created"
        case muxKilled = "mux:killed"
        case muxDied = "mux:died"
        case muxStatsUpdated = "mux:statsUpdated"

        // Remote auto-reconnect
        case remoteSessionDropped = "remote:sessionDropped"
        case remoteSessionReconnected = "remote:sessionReconnected"
        case remoteReconnectExhausted = "remote:reconnectExhausted"

        // Respawn
        case respawnStarted = "respawn:started"
        case respawnStopped = "respawn:stopped"
        case respawnStateChanged = "respawn:stateChanged"
        case respawnCycleStarted = "respawn:cycleStarted"
        case respawnCycleCompleted = "respawn:cycleCompleted"
        case respawnBlocked = "respawn:blocked"
        case respawnStepSent = "respawn:stepSent"
        case respawnStepCompleted = "respawn:stepCompleted"
        case respawnDetectionUpdate = "respawn:detectionUpdate"
        case respawnAutoAcceptSent = "respawn:autoAcceptSent"
        case respawnAiCheckStarted = "respawn:aiCheckStarted"
        case respawnAiCheckCompleted = "respawn:aiCheckCompleted"
        case respawnAiCheckFailed = "respawn:aiCheckFailed"
        case respawnAiCheckCooldown = "respawn:aiCheckCooldown"
        case respawnPlanCheckStarted = "respawn:planCheckStarted"
        case respawnPlanCheckCompleted = "respawn:planCheckCompleted"
        case respawnPlanCheckFailed = "respawn:planCheckFailed"
        case respawnTimerStarted = "respawn:timerStarted"
        case respawnTimerCancelled = "respawn:timerCancelled"
        case respawnTimerCompleted = "respawn:timerCompleted"
        case respawnActionLog = "respawn:actionLog"
        case respawnLog = "respawn:log"
        case respawnError = "respawn:error"
        case respawnConfigUpdated = "respawn:configUpdated"

        // Subagents
        case subagentDiscovered = "subagent:discovered"
        case subagentUpdated = "subagent:updated"
        case subagentToolCall = "subagent:tool_call"
        case subagentToolResult = "subagent:tool_result"
        case subagentProgress = "subagent:progress"
        case subagentMessage = "subagent:message"
        case subagentCompleted = "subagent:completed"

        // Workflow runs (ultracode)
        case workflowRunDiscovered = "workflow:run_discovered"
        case workflowRunUpdated = "workflow:run_updated"
        case workflowRunRemoved = "workflow:run_removed"

        // Scheduled runs
        case scheduledCreated = "scheduled:created"
        case scheduledUpdated = "scheduled:updated"
        case scheduledCompleted = "scheduled:completed"
        case scheduledStopped = "scheduled:stopped"
        case scheduledLog = "scheduled:log"
        case scheduledDeleted = "scheduled:deleted"

        // Cron jobs
        case cronJobsChanged = "cron:jobsChanged"
        case cronJobDeleted = "cron:jobDeleted"
        case cronRunCreated = "cron:runCreated"
        case cronRunUpdated = "cron:runUpdated"

        // Teams
        case teamCreated = "team:created"
        case teamUpdated = "team:updated"
        case teamRemoved = "team:removed"
        case teamTaskUpdated = "team:taskUpdated"

        // Transcript
        case transcriptComplete = "transcript:complete"
        case transcriptPlanMode = "transcript:plan_mode"
        case transcriptToolStart = "transcript:tool_start"
        case transcriptToolEnd = "transcript:tool_end"

        // Plan orchestration
        case planStarted = "plan:started"
        case planProgress = "plan:progress"
        case planSubagent = "plan:subagent"
        case planCompleted = "plan:completed"
        case planCancelled = "plan:cancelled"

        // Tunnel
        case tunnelStarted = "tunnel:started"
        case tunnelStopped = "tunnel:stopped"
        case tunnelProgress = "tunnel:progress"
        case tunnelError = "tunnel:error"
        case tunnelQrRotated = "tunnel:qrRotated"
        case tunnelQrRegenerated = "tunnel:qrRegenerated"
        case tunnelQrAuthUsed = "tunnel:qrAuthUsed"

        // Image / attachments
        case imageDetected = "image:detected"
        case attachmentDetected = "attachment:detected"

        // Hooks
        case hookIdlePrompt = "hook:idle_prompt"
        case hookPermissionPrompt = "hook:permission_prompt"
        case hookElicitationDialog = "hook:elicitation_dialog"
        case hookElicitationComplete = "hook:elicitation_complete"
        case hookElicitationResponse = "hook:elicitation_response"
        case hookStop = "hook:stop"
        case hookTeammateIdle = "hook:teammate_idle"
        case hookTaskCompleted = "hook:task_completed"

        // Approvals inbox
        case approvalPending = "approval:pending"
        case approvalUpdated = "approval:updated"
        case approvalResolved = "approval:resolved"

        // Orchestrator
        case orchestratorStateChanged = "orchestrator:stateChanged"
        case orchestratorPlanProgress = "orchestrator:planProgress"
        case orchestratorPlanReady = "orchestrator:planReady"
        case orchestratorPhaseStarted = "orchestrator:phaseStarted"
        case orchestratorPhaseCompleted = "orchestrator:phaseCompleted"
        case orchestratorPhaseFailed = "orchestrator:phaseFailed"
        case orchestratorVerification = "orchestrator:verification"
        case orchestratorTaskAssigned = "orchestrator:taskAssigned"
        case orchestratorTaskCompleted = "orchestrator:taskCompleted"
        case orchestratorTaskFailed = "orchestrator:taskFailed"
        case orchestratorCompleted = "orchestrator:completed"
        case orchestratorError = "orchestrator:error"

        // Clipboard
        case clipboardWrite = "clipboard:write"

        // Cases
        case caseCreated = "case:created"
        case caseLinked = "case:linked"
        case caseDeleted = "case:deleted"
        case caseOrderChanged = "case:order-changed"

        // Docker cases
        case dockerExportComplete = "docker:exportComplete"
        case dockerExportFailed = "docker:exportFailed"
        case dockerImportComplete = "docker:importComplete"
        case dockerImageBuildStarted = "docker:imageBuildStarted"
        case dockerImageBuildProgress = "docker:imageBuildProgress"
        case dockerImageBuildComplete = "docker:imageBuildComplete"
        case dockerImageBuildFailed = "docker:imageBuildFailed"
        case dockerContainerRecreated = "docker:containerRecreated"

        // Multi-user
        case adminUsersChanged = "admin:usersChanged"
        case authPasswordChangeRequired = "auth:passwordChangeRequired"

        // Session order
        case sessionOrderChanged = "session:orderChanged"

        // Web tabs
        case webviewChanged = "webview:changed"
    }

    init(rawValue: String) {
        if let known = Known(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case let .known(k): k.rawValue
        case let .unknown(raw): raw
        }
    }

    var known: Known? {
        if case let .known(k) = self { return k }
        return nil
    }
}

/// One decoded SSE frame: the event name plus its still-encoded JSON payload.
///
/// The payload is kept as `Data` rather than eagerly decoded because the 155 event types have
/// 155 different payload shapes and the app only decodes the ~40 it acts on. Decoding the rest
/// would be pure cost and a source of spurious failures.
struct SSEFrame: Sendable {
    var name: SSEEventName
    var data: Data
    var id: String?
    var retry: Int?

    func decode<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder) -> T? {
        guard !data.isEmpty else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}

// MARK: - Common payloads

/// Most session-scoped events carry at least an id. Several spell it `id`, others `sessionId`.
struct SessionScopedPayload: Decodable, Sendable {
    var id: String?
    var sessionId: String?

    var resolvedID: String? { id ?? sessionId }
}

struct SessionUpdatedPayload: Decodable, Sendable {
    var session: SessionSnapshot
}

struct SessionTerminalPayload: Decodable, Sendable {
    var id: String?
    var sessionId: String?
    var data: String?

    var resolvedID: String? { id ?? sessionId }
}

struct HookEventPayload: Decodable, Sendable {
    var sessionId: String?
    var id: String?
    var message: String?
    var title: String?

    var resolvedID: String? { sessionId ?? id }
}

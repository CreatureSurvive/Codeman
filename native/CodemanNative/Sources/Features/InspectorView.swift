import SwiftUI

/// Detail column: what the selected session is doing right now.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    private var session: SessionSnapshot? {
        model.selectedSessionID.flatMap { model.session(id: $0) }
    }

    var body: some View {
        List {
            if let session {
                detailSection(session)
                usageSection(session)
                agentSection(session)
                automationSection(session)
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "sidebar.right")
            }

            if let usage = model.planUsage {
                planSection(usage)
            }
            if let stats = model.globalStats {
                fleetSection(stats)
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func detailSection(_ session: SessionSnapshot) -> some View {
        Section("Session") {
            LabeledContent("Status", value: statusText(session))
            if let mode = session.mode { LabeledContent("Backend", value: mode.displayName) }
            if let backend = session.backendBadge { LabeledContent("API", value: backend) }
            if let modelName = session.modelBadge { LabeledContent("Model", value: modelName) }
            if let version = session.cliVersion {
                LabeledContent("CLI") {
                    HStack(spacing: 4) {
                        Text(version)
                        if let latest = session.cliLatestVersion, latest != version {
                            Badge(text: "\(latest) available", tint: .orange)
                        }
                    }
                }
            }
            if let effort = session.effort { LabeledContent("Effort", value: effort) }
            if let dir = session.workingDir {
                LabeledContent("Directory") {
                    Text(dir).font(.caption.monospaced()).lineLimit(3).truncationMode(.head)
                }
            }
            if let location = session.locationBadge {
                LabeledContent(session.docker != nil ? "Container" : "Remote host", value: location)
            }
            if let created = session.createdDate {
                LabeledContent("Started", value: created.formatted(.relative(presentation: .named)))
            }
        }
    }

    @ViewBuilder
    private func usageSection(_ session: SessionSnapshot) -> some View {
        if session.inputTokens != nil || session.outputTokens != nil || session.totalCost != nil {
            Section("Usage") {
                if let input = session.inputTokens {
                    LabeledContent("Input tokens", value: input.formatted())
                }
                if let output = session.outputTokens {
                    LabeledContent("Output tokens", value: output.formatted())
                }
                if let cost = session.totalCost {
                    LabeledContent("Cost", value: cost.formatted(.currency(code: "USD")))
                }
            }
        }
    }

    @ViewBuilder
    private func agentSection(_ session: SessionSnapshot) -> some View {
        let related = model.subagents.filter { $0.sessionId == session.id }
        if !related.isEmpty {
            Section("Subagents") {
                ForEach(related) { agent in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(agent.name ?? agent.id).font(.callout)
                            Spacer()
                            if let status = agent.status {
                                Badge(text: status, tint: status == "running" ? .green : .secondary)
                            }
                        }
                        if let tool = agent.toolName {
                            Text(tool).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        if let description = agent.description {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }

        // Lineage: the sessions this one spawned, and the one that spawned it.
        let children = model.sessions.filter { $0.parentSessionId == session.id }
        if !children.isEmpty || session.parentSessionId != nil {
            Section("Lineage") {
                if let parentID = session.parentSessionId, let parent = model.session(id: parentID) {
                    Button {
                        model.selectedSessionID = parent.id
                    } label: {
                        Label(parent.displayName, systemImage: "arrow.turn.left.up")
                    }
                }
                ForEach(children) { child in
                    Button {
                        model.selectedSessionID = child.id
                    } label: {
                        Label(child.displayName, systemImage: "arrow.turn.down.right")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func automationSection(_ session: SessionSnapshot) -> some View {
        if session.respawnEnabled == true || session.ralphEnabled == true
            || session.respawnBlocked == true || session.autoResumeEnabled == true {
            Section("Automation") {
                if session.respawnEnabled == true {
                    LabeledContent("Respawn", value: "Running")
                }
                if session.respawnBlocked == true {
                    Label("Respawn blocked — the PTY-exit breaker tripped.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text("Restarting the terminal from its pane clears the breaker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if session.ralphEnabled == true {
                    LabeledContent("Ralph loop", value: session.ralphCompletionPhrase ?? "Enabled")
                }
                if session.autoResumeEnabled == true {
                    if let at = session.autoResumeAt, at > 0 {
                        LabeledContent(
                            "Auto-resume",
                            value: Date(timeIntervalSince1970: at / 1000).formatted(.relative(presentation: .named))
                        )
                    } else {
                        LabeledContent("Auto-resume", value: "Armed")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func planSection(_ usage: PlanUsage) -> some View {
        Section("Plan usage") {
            if let session = usage.sessionPercent { usageRow("Session", session) }
            if let weekly = usage.weeklyPercent { usageRow("Weekly", weekly) }
            if let opus = usage.opusWeeklyPercent { usageRow("Opus weekly", opus) }
            if let resets = usage.resetsAt, resets > 0 {
                LabeledContent(
                    "Resets",
                    value: Date(timeIntervalSince1970: resets / 1000).formatted(.relative(presentation: .named))
                )
            }
        }
    }

    private func usageRow(_ label: String, _ percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(percent.rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(percent / 100, 0), 1))
                .tint(percent > 85 ? .red : percent > 60 ? .orange : .accentColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) usage \(Int(percent.rounded())) percent")
    }

    @ViewBuilder
    private func fleetSection(_ stats: GlobalStats) -> some View {
        Section("Fleet") {
            if let created = stats.sessionsCreated {
                LabeledContent("Sessions created", value: created.formatted())
            }
            if let input = stats.totalInputTokens, let output = stats.totalOutputTokens {
                LabeledContent("Tokens", value: (input + output).formatted())
            }
            if let cost = stats.totalCost {
                LabeledContent("Total cost", value: cost.formatted(.currency(code: "USD")))
            }
        }
    }

    private func statusText(_ session: SessionSnapshot) -> String {
        if model.needsAttention.contains(session.id) { return "Needs your input" }
        if model.waitingForInput.contains(session.id) { return "Waiting for a prompt" }
        switch session.effectiveStatus {
        case .busy: return "Working"
        case .idle: return session.pid == nil ? "Not running" : "Idle"
        case .stopped: return "Stopped"
        case .error: return "Error"
        }
    }
}

// Ops Board sidebar — unified ops view: usage meters + grouped workspaces.
// Adapted from cmux-sentinel's workspaces.swift predicates (proven on 0.65.x).
//
// Interpreter traps honored here (see sentinel header):
//   - NO nil comparisons (x != nil is falsy on 0.64.x, inverted on 0.65.x).
//     Guard optional fields by shape: .count > 0 on strings/arrays, == true on Bools.
//   - `||` is not trusted; use nested ternaries.
//   - `var` mutation and `return` inside `for` loops silently no-op; use .filter/.map.
//   - Buttons cannot nest: the close × is an .overlay Button on the select Button.

// ── meter predicates (sentinel titles: "<anchor> |<detail>|<bar>") ──
func isClaudeMeter(_ w) -> Bool {
  if w.title == "5h" { return true }
  if w.title.hasPrefix("5h ") { return true }
  if w.title == "7d" { return true }
  if w.title.hasPrefix("7d ") { return true }
  if w.title == "m7d" { return true }
  if w.title.hasPrefix("m7d ") { return true }
  if w.title == "spend" { return true }
  if w.title.hasPrefix("spend ") { return true }
  return false
}
func isZeroSpend(_ w) -> Bool {
  if w.title == "spend" { return true }
  if w.title.hasPrefix("spend |none|") { return true }
  return false
}
func isClaudePanelRow(_ w) -> Bool {
  if isZeroSpend(w) { return false }
  if isClaudeMeter(w) { return true }
  return false
}
func isCodexMeter(_ w) -> Bool {
  if w.title == "cx5h" { return true }
  if w.title.hasPrefix("cx5h ") { return true }
  if w.title == "cx7d" { return true }
  if w.title.hasPrefix("cx7d ") { return true }
  return false
}
func isAmpMeter(_ w) -> Bool {
  if w.title == "ampu" { return true }
  if w.title.hasPrefix("ampu ") { return true }
  if w.title == "ampo" { return true }
  if w.title.hasPrefix("ampo ") { return true }
  return false
}
func isUsageMeter(_ w) -> Bool {
  if isClaudeMeter(w) { return true }
  if isCodexMeter(w) { return true }
  if isAmpMeter(w) { return true }
  return false
}

// Sort rank: short window first (0), weekly (1), spend/m7d tail (2).
func meterRank(_ w) -> Int {
  if w.title.hasPrefix("5h") { return 0 }
  if w.title.hasPrefix("7d") { return 1 }
  if w.title.hasPrefix("cx5h") { return 0 }
  if w.title.hasPrefix("cx7d") { return 1 }
  if w.title.hasPrefix("ampu") { return 0 }
  if w.title.hasPrefix("ampo") { return 0 }
  return 2
}

func meterWindow(_ w) -> String {
  if w.title == "5h" { return "session" }
  if w.title.hasPrefix("5h ") { return "session" }
  if w.title == "7d" { return "week" }
  if w.title.hasPrefix("7d ") { return "week" }
  if w.title == "cx5h" { return "session" }
  if w.title.hasPrefix("cx5h ") { return "session" }
  if w.title == "cx7d" { return "week" }
  if w.title.hasPrefix("cx7d ") { return "week" }
  if w.title == "ampu" { return "threads" }
  if w.title.hasPrefix("ampu ") { return "threads" }
  if w.title == "ampo" { return "orbs" }
  if w.title.hasPrefix("ampo ") { return "orbs" }
  if w.title == "m7d" { return "model" }
  if w.title.hasPrefix("m7d ") {
    let parts = w.title.split(separator: "|")
    if parts.count > 3 { return String(parts[3]) }
    return "model"
  }
  if w.title == "spend" { return "credits" }
  if w.title.hasPrefix("spend ") { return "credits" }
  return "usage"
}
func meterFallbackDetail(_ w) -> String {
  if w.title == "5h" { return "waiting…" }
  if w.title == "7d" { return "waiting…" }
  if w.title == "cx5h" { return "waiting…" }
  if w.title == "cx7d" { return "waiting…" }
  if w.title == "ampu" { return "waiting…" }
  if w.title == "ampo" { return "waiting…" }
  let parts = w.title.split(separator: "|")
  if parts.count > 1 { return String(parts[1]) }
  return "refreshing…"
}
func meterFallbackBar(_ w) -> String {
  let parts = w.title.split(separator: "|")
  if parts.count > 2 { return String(parts[2]) }
  return ""
}
func meterNote(_ w) -> String {
  if w.title.hasPrefix("m7d ") { return "" }
  let parts = w.title.split(separator: "|")
  if parts.count > 3 { return String(parts[3]) }
  return ""
}

func meterRow(_ w) -> some View {
  VStack(alignment: .leading, spacing: 3) {
    HStack(spacing: 6) {
      Text(meterWindow(w))
        .font(.system(size: 11, design: .monospaced)).foregroundColor("#9CA3AF")
      Spacer()
      Text(meterFallbackDetail(w))
        .font(.system(size: 10, design: .monospaced)).foregroundColor("#6B7280")
        .lineLimit(1).truncationMode(.tail)
    }
    if meterFallbackBar(w) != "" {
      Text(meterFallbackBar(w))
        .font(.system(size: 10, design: .monospaced)).foregroundColor("#38BDF8")
        .lineLimit(1)
    }
    if meterNote(w) != "" {
      Text(meterNote(w))
        .font(.system(size: 9, design: .monospaced)).foregroundColor("#6B7280")
        .lineLimit(1)
    }
  }
}

// ── group / workspace predicates ──
// A group anchor is a workspace whose id appears as some group's anchorId.
func isGroupAnchor(_ w) -> Bool {
  if groups.count > 0 {
    return groups.filter { $0.anchorId == w.id }.count > 0
  }
  return false
}
func inCollapsedGroup(_ w) -> Bool {
  if groups.count > 0 {
    return groups.filter { $0.id == w.group && $0.collapsed == true }.count > 0
  }
  return false
}

// Agent freshness: 15 minutes, matching the board's "recently active" window.
// needs_input is gated by the same freshness so Claude's ~60s idle
// needs_input false-positive can't light a row up forever.
func agentFresh(_ a) -> Bool {
  return clock.epoch - a.lastActivityAt < 900
}
func agentWorking(_ w) -> Bool {
  if w.agents.count > 0 {
    return w.agents.filter { $0.status == "working" && agentFresh($0) }.count > 0
  }
  return false
}
func agentNeedsInput(_ w) -> Bool {
  if w.agents.count > 0 {
    return w.agents.filter { $0.status == "needs_input" && agentFresh($0) && $0.kind != "claude" }.count > 0
  }
  return false
}
// "busy" for the collapsed-group peek: a live agent, unread, or the selected row.
func wsBusy(_ w) -> Bool {
  if agentWorking(w) { return true }
  if w.unread > 0 { return true }
  if w.id == selectedId { return true }
  return false
}
func wsStatusColor(_ w) -> String {
  if agentWorking(w) { return "#F59E0B" }
  if w.unread > 0 { return "#10B981" }
  return "#52525B"
}
func wsStatusDot(_ w) -> some View {
  Circle().frame(width: 7, height: 7).foregroundColor(wsStatusColor(w))
}
func wsDescColor(_ w) -> String {
  if w.description.count == 0 { return "#52525B" }
  if w.description.contains("✗") { return "#EF4444" }
  if w.description.contains("✓appr") { return "#10B981" }
  return "#52525B"
}
func pad2(_ n: Int) -> String { return n < 10 ? "0\(n)" : "\(n)" }
func clockText() -> String { return "\(pad2(clock.hour)):\(pad2(clock.minute))" }
func groupIndent(_ depth: Int) -> Double {
  return Double(depth) * 12.0
}
func groupDepth(_ name: String) -> Int {
  return name.split(separator: "/").count - 1
}
func groupLeaf(_ name: String) -> String {
  let parts = name.split(separator: "/")
  if parts.count > 0 { return String(parts[parts.count - 1]) }
  return name
}

// One workspace row: status dot, title, unread badge, description, close ×.
// `indent` is the leading padding for slash-nested group members (0 elsewhere).
func wsRow(_ w, indent: Double) -> some View {
  Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
    HStack(spacing: 7) {
      wsStatusDot(w)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 5) {
          Text(w.title)
            .font(.system(size: 12, design: .monospaced))
            .fontWeight(w.selected == true ? .bold : .regular)
            .foregroundColor(w.selected == true ? "#F9FAFB" : "#D4D4D8")
            .lineLimit(1).truncationMode(.tail)
          if w.unread > 0 {
            Text("\(w.unread)")
              .font(.system(size: 9, design: .monospaced))
              .foregroundColor("#0B0F17")
              .padding(.horizontal, 4).padding(.vertical, 1)
              .background(Capsule().foregroundColor("#10B981"))
          }
        }
        if w.description.count > 0 {
          Text(w.description)
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(wsDescColor(w))
            .lineLimit(1).truncationMode(.tail)
        }
      }
      Spacer()
      Rectangle().opacity(0).frame(width: 20, height: 20)
    }
    .padding(.leading, indent)
    .padding(6)
  }
  .overlay(alignment: .trailing) {
    Button(action: { cmux("workspace.close", workspace_id: w.id) }) {
      Image(systemName: "xmark")
        .font(.system(size: 9)).foregroundColor("#71717A")
        .frame(width: 20, height: 20)
    }
    .padding(6)
  }
  .contextMenu {
    Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
      Label("Open", systemImage: "arrow.right.circle")
    }
    Button(action: { cmux("workspace.action", workspace_id: w.id, action: "pin") }) {
      Label("Pin", systemImage: "pin")
    }
    Button(action: { cmux("workspace.action", workspace_id: w.id, action: "unpin") }) {
      Label("Unpin", systemImage: "pin.slash")
    }
    if w.unread > 0 {
      Button(action: { cmux("workspace.action", workspace_id: w.id, action: "mark_read") }) {
        Label("Mark read", systemImage: "envelope.open")
      }
    } else {
      Button(action: { cmux("workspace.action", workspace_id: w.id, action: "mark_unread") }) {
        Label("Mark unread", systemImage: "envelope.badge")
      }
    }
    Divider()
    Button(action: { cmux("workspace.close", workspace_id: w.id) }) {
      Label("Close", systemImage: "xmark")
    }
  }
}

// ── layout ──
let regular = workspaces.filter { !isUsageMeter($0) && !isGroupAnchor($0) }
let ungrouped = regular.filter { $0.group.count == 0 }
let workingCount = regular.filter { agentWorking($0) || agentNeedsInput($0) }.count
let unreadCount = regular.filter { $0.unread > 0 }.count

VStack(alignment: .leading, spacing: 0) {
  HStack(spacing: 8) {
    Text("Ops Board")
      .font(.system(size: 13, design: .monospaced)).bold()
      .foregroundColor("#F9FAFB")
    Spacer()
    if workingCount > 0 {
      Text("\(workingCount) working")
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor("#F59E0B")
    }
    if unreadCount > 0 {
      Text("\(unreadCount) unread")
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor("#10B981")
    }
    Text(clockText())
      .font(.system(size: 10, design: .monospaced))
      .foregroundColor("#71717A")
  }
  .padding(9)
  Divider()

  // CLAUDE USAGE
  if workspaces.filter { isClaudePanelRow($0) }.count > 0 {
    VStack(alignment: .leading, spacing: 4) {
      Text("CLAUDE USAGE")
        .font(.system(size: 9, design: .monospaced)).bold()
        .foregroundColor("#71717A")
        .padding(.horizontal, 9)
      ForEach(workspaces.filter { isClaudePanelRow($0) }.sorted { meterRank($0) < meterRank($1) }) { w in
        meterRow(w).padding(.horizontal, 9)
      }
    }
    .padding(.vertical, 6)
    Divider()
  }

  // CODEX USAGE
  if workspaces.filter { isCodexMeter($0) }.count > 0 {
    VStack(alignment: .leading, spacing: 4) {
      Text("CODEX USAGE")
        .font(.system(size: 9, design: .monospaced)).bold()
        .foregroundColor("#71717A")
        .padding(.horizontal, 9)
      ForEach(workspaces.filter { isCodexMeter($0) }.sorted { meterRank($0) < meterRank($1) }) { w in
        meterRow(w).padding(.horizontal, 9)
      }
    }
    .padding(.vertical, 6)
    Divider()
  }

  // AMP USAGE
  if workspaces.filter { isAmpMeter($0) }.count > 0 {
    VStack(alignment: .leading, spacing: 4) {
      Text("AMP USAGE")
        .font(.system(size: 9, design: .monospaced)).bold()
        .foregroundColor("#71717A")
        .padding(.horizontal, 9)
      ForEach(workspaces.filter { isAmpMeter($0) }.sorted { meterRank($0) < meterRank($1) }) { w in
        meterRow(w).padding(.horizontal, 9)
      }
    }
    .padding(.vertical, 6)
    Divider()
  }

  // GROUPED WORKSPACES — only when the host binds `groups`.
  if groups.count > 0 {
    ForEach(groups) { g in
      let members = regular.filter { $0.group == g.id && $0.id != g.anchorId }
      let visibleMembers = g.collapsed == true ? members.filter { wsBusy($0) } : members
      VStack(alignment: .leading, spacing: 0) {
        Button(action: {
          if g.collapsed == true {
            cmux("workspace.group.expand", group_id: g.id)
          } else {
            cmux("workspace.group.collapse", group_id: g.id)
          }
        }) {
          HStack(spacing: 5) {
            Image(systemName: g.collapsed == true ? "chevron.right" : "chevron.down")
              .font(.system(size: 9)).foregroundColor("#71717A")
            Text(groupLeaf(g.name))
              .font(.system(size: 10, design: .monospaced)).bold()
              .foregroundColor("#A1A1AA")
              .lineLimit(1).truncationMode(.tail)
            Spacer()
            if g.collapsed == true && members.count > visibleMembers.count {
              Text("+\(members.count - visibleMembers.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor("#52525B")
            }
          }
          .padding(.horizontal, 9).padding(.vertical, 5)
        }
        ForEach(visibleMembers.sorted { $0.index < $1.index }) { w in
          wsRow(w, indent: groupIndent(groupDepth(g.name)))
        }
      }
    }
  }

  // UNGROUPED WORKSPACES — drag-to-reorder persists via workspace.reorder.
  Reorderable(Array(ungrouped.sorted { $0.index < $1.index }.prefix(30)), move: "workspace.reorder") { w in
    wsRow(w, indent: 0)
  }
  Spacer()
}

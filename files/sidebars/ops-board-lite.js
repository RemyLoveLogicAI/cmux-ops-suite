// ops-board — unified ops sidebar: usage meters + agent/workspace board.
//
// One left sidebar that combines what the suite produces:
//   • provider usage meters (claude/codex/amp sentinels, title-anchored)
//   • live workspace rows with branch/PR/description/agent state
//   • drag-to-reorder via workspace.reorder (persisted)
//
// Data contract (same host keys as every custom sidebar):
//   data.workspaces() → [{ id, title, selected, pinned, index, directory,
//     description?, branch?, dirty?, pr?, progress?, unread, agents?, tabs? }]
// Meter rows are workspaces whose title starts with a sentinel label
// ("5h ", "7d ", "cx5h ", "cx7d ", "ampu ", "ampo ", "m7d ", "spend ").
//
// Install: this file IS the sidebar — pick "ops-board" from the sidebar
// toggle's right-click menu, or `cmux sidebar select ops-board`.
// Validate: cmux sidebar validate ops-board

// --- meter predicates ---------------------------------------------------------
// Title-anchored like the sentinel's own workspaces.swift: exact label or
// "<label> " prefix. "spend" hides itself while the balance is zero.
const isClaudeMeter = (t) =>
  t === "5h" || t.startsWith("5h ") ||
  t === "7d" || t.startsWith("7d ") ||
  t === "m7d" || t.startsWith("m7d ") ||
  t === "spend" || t.startsWith("spend ");
const isCodexMeter = (t) =>
  t === "cx5h" || t.startsWith("cx5h ") ||
  t === "cx7d" || t.startsWith("cx7d ");
const isAmpMeter = (t) =>
  t === "ampu" || t.startsWith("ampu ") ||
  t === "ampo" || t.startsWith("ampo ");
const isMeter = (w) => {
  const t = w.title || "";
  return isClaudeMeter(t) || isCodexMeter(t) || isAmpMeter(t);
};
const isZeroSpend = (t) => t === "spend" || t.startsWith("spend |none|");
const claudeRows = (ws) => ws.filter((w) => isClaudeMeter(w.title) && !isZeroSpend(w.title));
const codexRows = (ws) => ws.filter((w) => isCodexMeter(w.title));
const ampRows = (ws) => ws.filter((w) => isAmpMeter(w.title));
const boardRows = (ws) => ws.filter((w) => !isMeter(w));

// Meter title protocol: "<anchor> |<detail>|<bar>" (optional 4th "|note").
function meterParts(w) {
  const t = w.title || "";
  const parts = t.split("|");
  const anchor = parts[0].trim();
  return {
    anchor,
    detail: parts.length > 1 ? parts[1] : "waiting…",
    bar: parts.length > 2 ? parts[2] : "",
    note: parts.length > 3 ? parts[3] : "",
  };
}
const meterWindow = (w) => {
  const t = w.title || "";
  if (t.startsWith("5h") || t.startsWith("cx5h")) return "session";
  if (t.startsWith("7d") || t.startsWith("cx7d")) return "week";
  if (t.startsWith("m7d")) {
    const p = t.split("|");
    return p.length > 3 ? p[3] : "model";
  }
  if (t.startsWith("ampu")) return "threads";
  if (t.startsWith("ampo")) return "orbs";
  if (t.startsWith("spend")) return "credits";
  return "usage";
};
// Sort meters: short window first within each provider.
const shortFirst = (a, b) =>
  ((a.title || "").match(/^(5h|cx5h|ampu)/) ? 0 : 1) -
  ((b.title || "").match(/^(5h|cx5h|ampu)/) ? 0 : 1);

function meterRow(w) {
  const m = meterParts(w);
  return VStack({ spacing: 2 }, [
    HStack({ spacing: 6 }, [
      Text(() => meterWindow(w)).font(11).monospaced().color("secondary"),
      Spacer({ minLength: 4 }),
      Text(() => m.detail).font(11).monospaced().color("tertiary")
        .lineLimit(1).truncation("tail"),
    ]),
    m.bar
      ? HStack({ spacing: 6 }, [
          Text(() => m.bar).font(11).monospaced().color("#73D0FF").lineLimit(1),
          m.note ? Spacer({ minLength: 4 }) : null,
          m.note ? Text(() => m.note).font(11).monospaced().color("tertiary").lineLimit(1) : null,
        ])
      : null,
  ]).paddingHorizontal(10).paddingVertical(3);
}

function meterSection(title, rowsFn) {
  return computed(() => {
    const rows = rowsFn(data.workspaces() ?? []);
    if (rows.length === 0) return null;
    return VStack({ spacing: 4 }, [
      Text(title).font(10).bold().monospaced().color("tertiary")
        .paddingHorizontal(10).paddingTop(8),
      ...rows.sort(shortFirst).map((w) => meterRow(w)),
      Divider(),
    ]);
  });
}

// --- workspace rows -----------------------------------------------------------
const [selectOverride, setSelectOverride] = signal(null);
const [selectTick, setSelectTick] = signal(0);
function isSelected(w) {
  selectTick();
  if (selectOverride && w && selectOverride.id === w.id) {
    if (w.selected === selectOverride.sel) setSelectOverride(null);
    else return selectOverride.sel;
  }
  return w ? w.selected : false;
}
function selectWorkspace(w) {
  setSelectOverride({ id: w.id, sel: !w.selected });
  setSelectTick(selectTick() + 1);
  cmux("workspace.select", { workspace_id: w.id });
}
function closeWorkspace(id) {
  cmux("workspace.close", { workspace_id: id });
}

const agentDot = (a) => {
  if (a.status === "needs_input") return "#FF9F0A";
  if (a.status === "working") return "#30D158";
  if (a.status === "ended") return "#8E8E93";
  return "#636366"; // idle
};
const agentLine = (w) => {
  const agents = w.agents || [];
  if (agents.length === 0) return null;
  const busy = agents.filter((a) => a.status === "working" || a.status === "needs_input");
  const shown = busy.length > 0 ? busy : agents.slice(0, 2);
  return HStack({ spacing: 4 }, shown.slice(0, 3).map((a) =>
    HStack({ spacing: 3 }, [
      Circle({ size: 6 }).fill(agentDot(a)),
      Text(() => a.name || a.kind || "agent").font(10).monospaced().color("tertiary")
        .lineLimit(1),
    ])
  ));
};

function workspaceRow(w) {
  return ZStack({ alignment: "trailing" }, [
    VStack({ alignment: "leading", spacing: 1 }, [
      HStack({ spacing: 5 }, [
        Circle({ size: 6 }).fill(() => (isSelected(w()) ? "accent" : "clear")),
        Text(() => w()?.title || "").font(13).lineLimit(1).truncation("tail")
          .marquee()
          .color(() => (isSelected(w()) ? "primary" : "secondary")),
        w()?.dirty ? Text("*").font(11).bold().color("#FFCC66") : null,
        w()?.pinned ? Image("pin.fill").font(8).color("tertiary") : null,
        Spacer({ minLength: 0 }),
      ]),
      // ops line: branch + PR + description (poller-written) + agents
      HStack({ spacing: 6 }, [
        w()?.branch ? Text(() => w().branch).font(10).monospaced().color("tertiary").lineLimit(1) : null,
        w()?.pr ? Text(() => "PR#" + w().pr.number).font(10).monospaced()
          .color(() => (w().pr.status === "open" ? "#30D158" : w().pr.status === "merged" ? "#BF5AF2" : "tertiary"))
          .lineLimit(1) : null,
        w()?.description ? Text(() => w().description).font(10).monospaced().color("tertiary")
          .lineLimit(1).truncation("tail") : null,
        Spacer({ minLength: 0 }),
      ]),
      agentLine(w),
    ]).paddingHorizontal(10).paddingVertical(5),
    ZStack({}, [
      Text(() => (w()?.unread > 0 ? String(w().unread) : ""))
        .font("caption2").bold().color("white")
        .paddingHorizontal(() => (w()?.unread > 0 ? 5 : 0))
        .paddingVertical(() => (w()?.unread > 0 ? 1 : 0))
        .background(() => (w()?.unread > 0 ? "#E4573D" : null))
        .cornerRadius(7)
        .hideOnHover(),
      Image("xmark")
        .font(9).weight("semibold").color("secondary")
        .padding(4).cornerRadius(9)
        .hoverBackground("#7f7f7f4a")
        .showOnHover()
        .onTap(() => closeWorkspace(w().id)),
    ]),
  ])
    .cornerRadius(8)
    .background(() => (isSelected(w()) ? "#7f7f7f3d" : null))
    .hoverBackground(() => (isSelected(w()) ? "#7f7f7f3d" : "#7f7f7f24"))
    .frame({ maxWidth: "infinity" })
    .onTap(() => selectWorkspace(w()))
    .contextMenu([
      Button("Open", () => cmux("workspace.select", { workspace_id: w().id })),
      Button(() => (w()?.pinned ? "Unpin" : "Pin"), () =>
        cmux("workspace.action", { action: w()?.pinned ? "unpin" : "pin", workspace_id: w().id })),
      Button(() => (w()?.unread > 0 ? "Mark as Read" : "Mark as Unread"), () =>
        cmux("workspace.action", { action: w()?.unread > 0 ? "mark_read" : "mark_unread", workspace_id: w().id })),
      Divider(),
      Button("Close", () => closeWorkspace(w().id)).destructive(),
    ]);
}

// --- root ----------------------------------------------------------------------
sidebar(() =>
  VStack({ spacing: 4 }, [
    HStack({ spacing: 8 }, [
      Text("OPS").font(12).bold().monospaced().color("primary"),
      Spacer(),
      Text(() => clockText()).font(11).monospaced().color("tertiary"),
    ]).paddingHorizontal(10).paddingTop(8),
    Divider(),
    meterSection("CLAUDE", claudeRows),
    meterSection("CODEX", codexRows),
    meterSection("AMP", ampRows),
    HStack({ spacing: 8 }, [
      Text("WORKSPACES").font(10).bold().monospaced().color("tertiary"),
      Spacer(),
      Text(() => String(boardRows(data.workspaces() ?? []).length))
        .font(10).monospaced().color("tertiary"),
    ]).paddingHorizontal(10).paddingTop(6),
    Divider(),
    Reorderable(
      {
        items: () => boardRows(data.workspaces() ?? []).sort((a, b) => (a.index ?? 0) - (b.index ?? 0)),
        key: (w) => w.id,
        spacing: 2,
        onMove: (id, index) => cmux("workspace.reorder", { workspace_id: id, index }),
      },
      (w, key) => workspaceRow(w)
    ),
    Spacer(),
  ]),
  { surface: "glass" }
);

function clockText() {
  const c = data.clock ? data.clock() : null;
  if (!c) return "";
  const p = (n) => (n < 10 ? "0" + n : "" + n);
  return p(c.hour) + ":" + p(c.minute);
}

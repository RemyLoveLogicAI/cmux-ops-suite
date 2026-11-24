// memory-board — unified memory sidebar.
//
// Reads the `mem-board` carrier workspace's description, which board.py
// refreshes every 60s via launchd (com.cmux.memory-board) with a compact
// JSON snapshot of:
//   tf[]  TypeFire vault notes   {t, rel, excerpt}
//   lp[]  LifeOS projects        {n, s}
//   oh[]  OH HAI pending items   {t, ty, st}
//   sm[]  Supermemory results    {t, s}
//   smq   last supermemory query
//
// The board itself is read-only state injected into this sidebar — there is
// no HTTP server. Files:
//   ~/.config/cmux/memory/state.json   (full snapshot)
//   ~/.config/cmux/memory/env          (SUPERMEMORY_API_KEY, chmod 600)
//
// Install: ~/.config/cmux/sidebars/memory-board.js
// Validate: cmux sidebar validate memory-board

function carrierState() {
  const ws = data.workspaces() ?? [];
  const c = ws.find((w) => (w.title || "") === "mem-board");
  if (!c || !(c.description || "").startsWith("{")) return null;
  try { return JSON.parse(c.description); } catch { return null; }
}

const ago = (ts) => {
  if (!ts) return "";
  const d = Math.floor(Date.now() / 1000) - ts;
  if (d < 60) return "now";
  if (d < 3600) return Math.floor(d / 60) + "m";
  if (d < 86400) return Math.floor(d / 3600) + "h";
  return Math.floor(d / 86400) + "d";
};

// section(title, countFn, itemsFn, renderFn) — renders null when empty.
function section(title, countFn, itemsFn, renderFn) {
  return computed(() => {
    const items = itemsFn() || [];
    if (items.length === 0) return null;
    return VStack({ spacing: 2 }, [
      HStack({ spacing: 6 }, [
        Text(title).font(10).bold().monospaced().color("tertiary"),
        Spacer(),
        Text(() => String(countFn())).font(10).monospaced().color("tertiary"),
      ]).paddingHorizontal(10).paddingTop(8),
      ForEach({ items: itemsFn, key: (n, i) => i }, renderFn),
      Divider(),
    ]);
  });
}

// row(getTitle, getSub, getMeta, getAccent)
function row(getTitle, getSub, getMeta, getAccent) {
  return VStack({ alignment: "leading", spacing: 1 }, [
    Text(() => getTitle()).font(12).lineLimit(1).truncation("tail")
      .color(() => (getAccent ? getAccent() : "primary")),
    getSub ? Text(() => getSub()).font(10).color("secondary").lineLimit(2) : null,
    getMeta ? Text(() => getMeta()).font(9).monospaced().color("tertiary").lineLimit(1) : null,
  ]).paddingHorizontal(10).paddingVertical(3);
}

sidebar(() => {
  const st = computed(carrierState);
  return VStack({ spacing: 4 }, [
    HStack({ spacing: 8 }, [
      Text("MEMORY").font(12).bold().monospaced().color("primary"),
      Spacer(),
      Button("state.json",
        () => openURL("file:///Users/lovelogic/.config/cmux/memory/state.json"))
        .font(10).monospaced(),
    ]).paddingHorizontal(10).paddingTop(8),
    Divider(),

    section("TYPEFIRE",
      () => (st()?.tf || []).length,
      () => (st()?.tf || []).slice(0, 8),
      (n) => row(
        () => n().t,
        () => n().excerpt || "",
        () => n().rel,
      )),

    section("LIFEOS",
      () => (st()?.lp || []).length,
      () => (st()?.lp || []).slice(0, 10),
      (p) => row(
        () => p().n,
        () => p().s || "",
        () => "~/.config/LIFEOS/USER/PROJECTS.md",
      )),

    section("OH HAI",
      () => (st()?.oh || []).length,
      () => (st()?.oh || []).slice(0, 8),
      (m) => row(
        () => m().t,
        () => m().ty + " · " + m().st,
        () => "",
        () => (m().st === "open" ? "#FF9F0A" : null),
      )),

    section("SUPERMEMORY",
      () => (st()?.sm || []).length,
      () => (st()?.sm || []).slice(0, 5),
      (r) => row(
        () => r().t,
        () => r().s || "",
        () => "",
      )),

    // Mem note — always visible (not data-driven)
    computed(() =>
      VStack({ spacing: 2 }, [
        HStack({ spacing: 6 }, [
          Text("MEM").font(10).bold().monospaced().color("tertiary"),
          Spacer(),
          Text("1").font(10).monospaced().color("tertiary"),
        ]).paddingHorizontal(10).paddingTop(8),
        VStack({ alignment: "leading", spacing: 1 }, [
          Text("mem.ai").font(12).lineLimit(1),
          Text("MCP Router connector — not a local API").font(10).color("secondary").lineLimit(2),
          Text("use via MCP tools").font(9).monospaced().color("tertiary").lineLimit(1),
        ]).paddingHorizontal(10).paddingVertical(3),
        Divider(),
      ])
    ),

    HStack({ spacing: 6 }, [
      Text(() => st()?.ts ? "updated " + ago(st().ts) + " ago" : "waiting for board.py…")
        .font(9).monospaced().color("tertiary"),
      Spacer(),
      Text("state.json").font(9).monospaced().color("tertiary"),
    ]).paddingHorizontal(10).paddingBottom(8),

    Spacer(),
  ]);
}, { surface: "glass" });

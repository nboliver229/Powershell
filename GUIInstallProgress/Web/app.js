(async function(){
  const sections = document.getElementById("sections");
  const badge = document.getElementById("badge");
  const sub = document.getElementById("sub");
  const meta = document.getElementById("meta");
  const barFill = document.getElementById("barFill");
  const done = document.getElementById("done");
  const btnClose = document.getElementById("btnClose");

  const tabs = [
    document.getElementById("tabAll"),
    document.getElementById("tabBase"),
    document.getElementById("tabProd"),
  ];

  const logWrap = document.getElementById("logWrap");
  const logBox = document.getElementById("logBox");
  const logTitle = document.getElementById("logTitle");
  const logSub = document.getElementById("logSub");
  const btnCopyLog = document.getElementById("btnCopyLog");
  const btnOpenCmtrace = document.getElementById("btnOpenCmtrace");

  let currentFilter = "all";
  let serverSuggestedFilter = "all";
  let statusRefreshMs = 3000;
  let logRefreshMs = 1000;

  function setActiveTab(filter){
    currentFilter = filter;
    for(const t of tabs){
      const on = (t.dataset.filter === filter);
      t.classList.toggle("active", on);
      t.setAttribute("aria-selected", on ? "true" : "false");
    }
  }
  tabs.forEach(t => t.addEventListener("click", () => setActiveTab(t.dataset.filter)));
  tabs.forEach(t => t.addEventListener("click", () => { window.__userTouchedTabs = true; }));

  async function fetchJson(url, opts){
    const r = await fetch(url, Object.assign({ cache: "no-store" }, opts||{}));
    return await r.json();
  }

  btnCopyLog?.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(logBox.textContent || ""); } catch {}
  });
  btnOpenCmtrace?.addEventListener("click", async () => {
    try { await fetchJson("/api/openlog", { method: "POST" }); } catch {}
  });
  btnClose.addEventListener("click", async () => {
    btnClose.disabled = true;
    try { await fetchJson("/api/close", { method: "POST" }); } catch {}
  });

  function renderGroup(g){
    const section = document.createElement("div");
    section.className = "section";

    const header = document.createElement("div");
    header.className = "sectionHeader";

    const left = document.createElement("div");
    left.className = "sectionTitle";
    left.textContent = g.name;

    const right = document.createElement("div");
    right.className = "sectionBadge";
    right.textContent = `${g.count} / ${g.target}`;

    header.appendChild(left);
    header.appendChild(right);

    const grid = document.createElement("div");
    grid.className = "grid";

    for(const it of g.items){
      const card = document.createElement("div");
      card.className = "card " + (it.ok ? "ok" : "bad");

      const name = document.createElement("div");
      name.className = "name";
      name.textContent = it.name;

      const detail = document.createElement("div");
      detail.className = "detail";
      detail.textContent = it.detail;

      const state = document.createElement("div");
      state.className = "state";
      state.textContent = it.ok ? "Installed" : "Missing";

      card.appendChild(name);
      card.appendChild(detail);
      card.appendChild(state);
      grid.appendChild(card);
    }

    section.appendChild(header);
    section.appendChild(grid);
    return section;
  }

  function renderStatus(s){
    badge.textContent = `${s.totalCount} / ${s.totalTarget}`;
    sub.textContent = `Last checked: ${s.now}`;

    const pct = Math.max(0, Math.min(100, Math.round((s.totalCount / Math.max(1, s.totalTarget)) * 100)));
    barFill.style.width = pct + "%";

    statusRefreshMs = s.refreshMs || 3000;
    logRefreshMs = s.logRefreshMs || 1000;

    meta.textContent = `Mode: ${s.mode} • Default view: ${s.suggestedFilter.toUpperCase()} • Status: ${Math.round(statusRefreshMs/1000)}s • Log: ${Math.round(logRefreshMs/1000)}s`;

    if(serverSuggestedFilter !== s.suggestedFilter){
      serverSuggestedFilter = s.suggestedFilter;
      if(!window.__userTouchedTabs){
        setActiveTab(serverSuggestedFilter);
      }
    }

    sections.innerHTML = "";
    const byId = {};
    for(const g of s.groups){ byId[g.id] = g; }

    const showIds =
      currentFilter === "all" ? s.activeGroupIds :
      currentFilter === "base" ? ["base"] :
      currentFilter === "prod" ? ["prod"] : s.activeGroupIds;

    if(currentFilter === "prod" && !byId["prod"]){
      const warn = document.createElement("div");
      warn.className = "warn";
      warn.textContent = "Production group is not active for this run (mode).";
      sections.appendChild(warn);
    }

    for(const id of showIds){
      const g = byId[id];
      if(g) sections.appendChild(renderGroup(g));
    }

    if(s.done){
      done.style.display = "block";
      btnClose.disabled = false;
    } else {
      done.style.display = "none";
      btnClose.disabled = true;
    }
  }

  function renderLog(l){
    if(!l) return;
    if(l.enabled === false){
      logWrap.style.display = "none";
      return;
    }
    logWrap.style.display = "block";
    logTitle.textContent = l.title || "Log (live)";
    logSub.textContent = l.sub || "";
    const atBottom = (logBox.scrollTop + logBox.clientHeight + 20) >= logBox.scrollHeight;
    logBox.textContent = l.text || "";
    if(atBottom){ logBox.scrollTop = logBox.scrollHeight; }
  }

  async function statusLoop(){
    while(true){
      try{
        const s = await fetchJson("/api/status");
        renderStatus(s);
        if(s.done){
          setTimeout(async () => { try{ await fetchJson("/api/close", { method: "POST" }); } catch {} }, 1200);
          return;
        }
        await new Promise(r => setTimeout(r, statusRefreshMs));
      } catch(e){
        sub.textContent = "Error loading status…";
        await new Promise(r => setTimeout(r, 2000));
      }
    }
  }

  async function logLoop(){
    while(true){
      try{
        const l = await fetchJson("/api/log");
        renderLog(l);
        await new Promise(r => setTimeout(r, logRefreshMs));
      } catch(e){
        await new Promise(r => setTimeout(r, 2000));
      }
    }
  }

  setActiveTab("all");
  await Promise.all([statusLoop(), logLoop()]);
})();
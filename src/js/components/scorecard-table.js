import { define } from "nanotags";
import { atom } from "nanostores";

/**
 * <scorecard-table> — progressive enhancement over the server-rendered <table>.
 * It never creates rows: it filters (search + category), reorders (column sort),
 * and counts the existing DOM. With JS off the full table is already present.
 *
 * Expected markup (emitted by build.rb):
 *   .controls  > input.controls__search, .chip[data-cat], .controls__count
 *   table      > tr.grp[data-grp], tr[data-cat][data-name] with indicator cells
 *   thead th.sortable[data-col]   (col 0 = name, 1..6 = indicators)
 */
define("scorecard-table")
  .withRefs((r) => ({
    search: r.one(),
    count: r.one(),
    table: r.one(),
  }))
  .setup((ctx) => {
    const { search, count, table } = ctx.refs;
    const host = ctx.host;
    host.classList.add("js-ready");
    document.documentElement.classList.add("js-ready");

    const rows = ctx.getElements("tbody tr[data-name]");
    const groups = ctx.getElements("tbody tr.grp");
    const chips = ctx.getElements(".chip");
    const headers = ctx.getElements("thead th.sortable");
    const total = rows.length;

    const query = atom("");
    const category = atom("all");

    // ----- rank a cell's pass-state for sorting -----
    const rankCell = (row, col) => {
      const cell = row.children[col];
      if (!cell) return -1;
      if (cell.querySelector(".ok")) return 2;
      if (cell.querySelector(".warn")) return 1;
      if (cell.querySelector(".bad")) return 0;
      return -1;
    };

    // ----- filter -----
    const applyFilter = () => {
      const q = query.get().trim().toLowerCase();
      const cat = category.get();
      let shown = 0;
      for (const row of rows) {
        const matchQ = !q || row.dataset.name.includes(q);
        const matchC = cat === "all" || row.dataset.cat === cat;
        const visible = matchQ && matchC;
        row.hidden = !visible;
        if (visible) shown++;
      }
      // hide a group header when none of its rows are visible
      for (const g of groups) {
        const cat = g.dataset.grp;
        const any = rows.some((r) => r.dataset.cat === cat && !r.hidden);
        g.hidden = !any;
      }
      count.textContent = `Showing ${shown} of ${total}`;
    };

    // ----- sort within each group -----
    let sortState = { col: -1, dir: 1 };
    const applySort = (col) => {
      const dir = sortState.col === col && sortState.dir === 1 ? -1 : 1;
      sortState = { col, dir };

      for (const g of groups) {
        const cat = g.dataset.grp;
        const groupRows = rows.filter((r) => r.dataset.cat === cat);
        groupRows.sort((a, b) => {
          let d;
          if (col === 0) d = a.dataset.name.localeCompare(b.dataset.name);
          else if (col === 7) d = Number(b.dataset.cc) - Number(a.dataset.cc); // coverage-first
          else d = rankCell(b, col) - rankCell(a, col); // pass-first by default
          return d * dir;
        });
        // re-attach in sorted order right after the group header
        let anchor = g;
        for (const row of groupRows) {
          anchor.after(row);
          anchor = row;
        }
      }

      for (const h of headers) {
        const isActive = Number(h.dataset.col) === col;
        h.setAttribute(
          "aria-sort",
          isActive ? (dir === 1 ? "ascending" : "descending") : "none"
        );
      }
    };

    // ----- wiring -----
    ctx.on(search, "input", () => query.set(search.value));
    ctx.effect(query, applyFilter);
    ctx.effect(category, applyFilter);

    for (const chip of chips) {
      ctx.on(chip, "click", () => {
        category.set(chip.dataset.cat);
        for (const c of chips)
          c.setAttribute("aria-pressed", String(c === chip));
      });
    }

    for (const h of headers) {
      h.setAttribute("aria-sort", "none");
      ctx.on(h, "click", () => applySort(Number(h.dataset.col)));
    }

    applyFilter();
  });

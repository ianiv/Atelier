import Foundation

/// Style library files: a self-contained HTML page that browses the styles and writes prompts
/// from them in any browser, with the styles as JSON in a `<script type="application/json"
/// id="atelier-styles">` block that Atelier imports (docs/styles.md).
nonisolated enum StyleLibrary {
  /// The data block: the styles, with each one's thumbnail as a JPEG data URL when it has one.
  struct Document: Codable {
    var format = "atelier-styles"
    var version = 1
    var title: String
    var styles: [Entry]
  }

  struct Entry: Codable {
    var name: String
    var category: String?
    var subcategory: String?
    var template: String
    var negative: String?
    var notes: String?
    var thumbnail: String?
  }

  static let blockID = "atelier-styles"

  /// The page for `styles`, titled `title`; `thumbnail` gives a style's JPEG.
  static func html(title: String, styles: [Style], thumbnail: (UUID) -> Data?) throws -> String {
    let document = Document(
      title: title,
      styles: styles.map { style in
        Entry(
          name: style.name, category: style.category.nilIfEmpty, subcategory: style.subcategory.nilIfEmpty,
          template: style.template, negative: style.negative.nilIfEmpty, notes: style.notes.nilIfEmpty,
          thumbnail: thumbnail(style.id).map { "data:image/jpeg;base64," + $0.base64EncodedString() })
      })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    // JSONEncoder writes "/" as "\/", so the data can never close its script element early.
    let json = String(decoding: try encoder.encode(document), as: UTF8.self)
    return page
      .replacingOccurrences(of: "{{TITLE}}", with: escapeHTML(title))
      .replacingOccurrences(of: "{{DATA}}", with: json)
  }

  /// The styles and thumbnails (JPEG or PNG data) in a library page, or nil when it has no
  /// `atelier-styles` block.
  static func read(_ html: String) -> [(style: Style, thumbnail: Data?)]? {
    guard let open = html.range(of: #"<script[^>]*id\s*=\s*["']atelier-styles["'][^>]*>"#, options: .regularExpression),
          let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex),
          let document = try? JSONDecoder().decode(Document.self, from: Data(html[open.upperBound..<close.lowerBound].utf8))
    else { return nil }
    return document.styles.compactMap { entry in
      guard !entry.name.isEmpty, !entry.template.isEmpty else { return nil }
      let style = Style(
        name: entry.name, category: entry.category ?? "", subcategory: entry.subcategory ?? "",
        template: entry.template, negative: entry.negative ?? "", notes: entry.notes ?? "")
      return (style, entry.thumbnail.flatMap(imageData(fromDataURL:)))
    }
  }

  private static func imageData(fromDataURL url: String) -> Data? {
    guard url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ",") else { return nil }
    return Data(base64Encoded: String(url[url.index(after: comma)...]))
  }

  private static func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  /// The browser. Its `fill` mirrors `Style.apply`: each {{TAG}} takes its box's text, an empty
  /// one is dropped with the gap it leaves, and a template without {{SUBJECT}} gets it in front.
  private static let page = #"""
  <!doctype html>
  <html lang="en">
  <head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="generator" content="Atelier">
  <title>{{TITLE}}</title>
  <style>
  :root { --bg: #f6f6f4; --panel: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --line: #dcdcd8; --accent: #0a66d8; --chip: #ececea; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #161617; --panel: #222224; --text: #f2f2f2; --muted: #a1a1a6; --line: #3a3a3c; --accent: #4c9bff; --chip: #2c2c2e; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
  header { position: sticky; top: 0; z-index: 2; display: flex; gap: 12px; align-items: center; padding: 12px 16px; background: var(--bg); border-bottom: 1px solid var(--line); }
  header h1 { font-size: 17px; margin: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  header .count { color: var(--muted); font-size: 13px; white-space: nowrap; }
  input[type=search], textarea, input.tag { font: inherit; color: var(--text); background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 7px 10px; }
  input[type=search] { margin-left: auto; width: min(320px, 45vw); }
  #list { padding: 8px 16px 24px; max-width: 1400px; margin: 0 auto; }
  .cats { position: relative; }
  .cats > button { font: inherit; font-size: 14px; color: var(--text); background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 7px 10px; cursor: pointer; white-space: nowrap; }
  .cats .menu { position: absolute; right: 0; top: calc(100% + 6px); z-index: 5; min-width: 280px; max-height: 70vh; overflow: auto; background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 8px; box-shadow: 0 10px 30px rgba(0,0,0,.25); }
  .cats .menu[hidden] { display: none; }
  .cats .menu label { display: flex; gap: 8px; align-items: center; padding: 5px 6px; border-radius: 6px; cursor: pointer; font-size: 14px; }
  .cats .menu label:hover { background: var(--chip); }
  .cats .menu label .n { margin-left: auto; color: var(--muted); font-size: 12px; }
  .cats .menu .bar { display: flex; gap: 6px; padding: 0 0 6px; margin-bottom: 4px; border-bottom: 1px solid var(--line); }
  dialog { width: min(920px, calc(100vw - 32px)); max-height: calc(100vh - 32px); padding: 0; border: 1px solid var(--line); border-radius: 14px; background: var(--panel); color: var(--text); }
  dialog::backdrop { background: rgba(0,0,0,.5); }
  .modal { display: grid; grid-template-columns: minmax(0, 340px) minmax(0, 1fr); gap: 20px; padding: 20px; }
  .modal.noimg { grid-template-columns: minmax(0, 1fr); }
  .modal img.big { width: 100%; border-radius: 10px; display: block; }
  .modal h2 { margin: 0 0 2px; font-size: 20px; padding-right: 36px; }
  .modal .sub { color: var(--muted); font-size: 13px; }
  .close { position: absolute; top: 12px; right: 12px; width: 30px; height: 30px; border-radius: 15px; border: 1px solid var(--line); background: var(--panel); color: var(--text); font-size: 18px; line-height: 1; cursor: pointer; }
  details { margin-top: 8px; }
  summary { cursor: pointer; font-weight: 600; padding: 6px 0; list-style: none; display: flex; gap: 8px; align-items: center; }
  summary::-webkit-details-marker { display: none; }
  summary::before { content: "›"; display: inline-block; transition: transform .15s; color: var(--muted); }
  details[open] > summary::before { transform: rotate(90deg); }
  summary .n { color: var(--muted); font-weight: 400; font-size: 13px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 10px; padding: 4px 0 8px; }
  .card { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; overflow: hidden; cursor: pointer; text-align: left; padding: 0; color: inherit; font: inherit; }
  .card:hover { border-color: var(--muted); }
  .card.sel { border-color: var(--accent); box-shadow: 0 0 0 2px var(--accent); }
  .thumb { width: 100%; aspect-ratio: 1; object-fit: cover; display: block; background: var(--chip); }
  .ph { width: 100%; aspect-ratio: 1; display: flex; align-items: center; justify-content: center; background: var(--chip); color: var(--muted); font-size: 28px; }
  .card .t { padding: 6px 8px 8px; }
  .card .name { font-weight: 600; font-size: 13px; line-height: 1.25; }
  .card .sub { color: var(--muted); font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  label.tl { display: block; margin: 12px 0 4px; font-size: 13px; color: var(--muted); }
  input.tag, textarea { width: 100%; }
  textarea { resize: vertical; min-height: 120px; }
  textarea.short { min-height: 54px; }
  .row { display: flex; gap: 8px; align-items: center; margin-top: 6px; }
  button.act { font: inherit; font-size: 13px; padding: 6px 12px; border-radius: 8px; border: 1px solid var(--line); background: var(--panel); color: var(--text); cursor: pointer; }
  button.act.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
  .note { color: var(--muted); font-size: 13px; white-space: pre-wrap; margin-top: 12px; }
  .empty { color: var(--muted); padding: 24px 0; }
  .ok { color: var(--muted); font-size: 12px; }
  @media (max-width: 700px) {
    .modal { grid-template-columns: 1fr; }
    header { flex-wrap: wrap; }
    input[type=search] { width: 100%; margin-left: 0; }
  }
  </style>
  </head>
  <body>
  <header>
    <h1>{{TITLE}}</h1>
    <span class="count" id="count"></span>
    <input type="search" id="q" placeholder="Search styles" aria-label="Search styles">
    <div class="cats">
      <button type="button" id="catsButton" aria-haspopup="true" aria-expanded="false"></button>
      <div class="menu" id="catsMenu" hidden></div>
    </div>
  </header>
  <main id="list"></main>
  <dialog id="modal"></dialog>
  <script type="application/json" id="atelier-styles">{{DATA}}</script>
  <script>
  (function () {
    const doc = JSON.parse(document.getElementById("atelier-styles").textContent);
    const styles = doc.styles || [];
    // {{TAG}} or {{TAG:default}}.
    const TAG = /\{\{([A-Za-z_][A-Za-z0-9_]*)(?::([^}]*))?\}\}/g;
    const store = {
      get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } },
      set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }
    };
    let values = store.get("atelier.values", {});
    // Categories you collapsed; every other one is open, new ones included.
    const closed = new Set(store.get("atelier.closed", []));
    let selected = store.get("atelier.selected", null);
    const allCats = [...new Set(styles.map(s => s.category || "Uncategorized"))];
    // The categories shown; every one until you pick.
    let shownCats = new Set((store.get("atelier.cats", null) || allCats).filter(c => allCats.includes(c)));
    const q = document.getElementById("q");
    q.value = store.get("atelier.query", "");

    function full(t) { return /\{\{SUBJECT(:[^}]*)?\}\}/.test(t) ? t : "{{SUBJECT}} " + t; }
    function defaults(t) { const d = {}; for (const m of full(t).matchAll(TAG)) { const v = (m[2] || "").trim(); if (v && !(m[1] in d)) d[m[1]] = v; } return d; }
    function tags(t) { const seen = []; for (const m of full(t).matchAll(TAG)) if (!seen.includes(m[1])) seen.push(m[1]); return seen; }
    function label(tag) { const w = tag.replace(/_/g, " ").toLowerCase(); return w.charAt(0).toUpperCase() + w.slice(1); }
    function fill(s) {
      const d = defaults(s.template);
      const p = full(s.template).replace(TAG, (_, tag) => (values[tag] || "").trim() || d[tag] || "").replace(/[ \t]{2,}/g, " ").trim();
      const n = [values.__negative || "", s.negative || ""].map(x => x.trim()).filter(Boolean).join(", ");
      return { prompt: p, negative: n };
    }
    function key(s) { return (s.category || "") + "\u0000" + s.name; }
    function el(tag, attrs, ...kids) {
      const e = document.createElement(tag);
      for (const [k, v] of Object.entries(attrs || {})) { if (k === "class") e.className = v; else if (k.startsWith("on")) e.addEventListener(k.slice(2), v); else e.setAttribute(k, v); }
      for (const k of kids) e.append(k);
      return e;
    }

    function renderList() {
      const query = q.value.trim().toLowerCase();
      const list = document.getElementById("list");
      list.textContent = "";
      const shown = styles.filter(s => shownCats.has(s.category || "Uncategorized")
        && (!query || [s.name, s.category, s.subcategory, s.template].some(x => (x || "").toLowerCase().includes(query))));
      document.getElementById("catsButton").textContent =
        (shownCats.size === allCats.length ? "All categories" : shownCats.size === 1 ? [...shownCats][0] : shownCats.size + " categories") + " ▾";
      document.getElementById("count").textContent = shown.length + " of " + styles.length + " styles";
      if (!shown.length) { list.append(el("p", { class: "empty" }, shownCats.size ? "No styles match." : "No categories picked: choose some from the menu above.")); return; }
      const groups = new Map();
      for (const s of shown) { const c = s.category || "Uncategorized"; if (!groups.has(c)) groups.set(c, []); groups.get(c).push(s); }
      for (const [cat, items] of groups) {
        const d = el("details");
        d.open = !!query || !closed.has(cat);
        d.addEventListener("toggle", () => { if (query) return; d.open ? closed.delete(cat) : closed.add(cat); store.set("atelier.closed", [...closed]); });
        d.append(el("summary", {}, cat, el("span", { class: "n" }, String(items.length))));
        const grid = el("div", { class: "grid" });
        for (const s of items) {
          const card = el("button", { class: "card" + (selected === key(s) ? " sel" : ""), type: "button", "data-key": key(s), onclick: () => select(s) },
            s.thumbnail ? el("img", { class: "thumb", src: s.thumbnail, alt: "", loading: "lazy" }) : el("div", { class: "ph" }, "🎨"),
            el("div", { class: "t" }, el("div", { class: "name" }, s.name), el("div", { class: "sub" }, s.subcategory || "")));
          grid.append(card);
        }
        d.append(grid);
        list.append(d);
      }
    }

    function copy(text, note) {
      const done = () => { note.textContent = "Copied"; setTimeout(() => note.textContent = "", 1500); };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, () => fallback());
      else fallback();
      function fallback() { const t = el("textarea"); t.value = text; document.body.append(t); t.select(); try { document.execCommand("copy"); done(); } catch (e) {} t.remove(); }
    }

    function openModal(s) {
      const dialog = document.getElementById("modal");
      dialog.textContent = "";
      const body = el("div", { class: "modal" + (s.thumbnail ? "" : " noimg") });
      if (s.thumbnail) body.append(el("div", {}, el("img", { class: "big", src: s.thumbnail, alt: "" })));
      const pane = el("div");
      pane.append(el("h2", {}, s.name), el("div", { class: "sub" }, [s.category, s.subcategory].filter(Boolean).join(" · ")));
      const out = el("textarea", { readonly: "", "aria-label": "Prompt" });
      const neg = el("textarea", { readonly: "", class: "short", "aria-label": "Negative prompt" });
      const update = () => { const r = fill(s); out.value = r.prompt; neg.value = r.negative; store.set("atelier.values", values); };
      let first = null;
      const d = defaults(s.template);
      for (const tag of tags(s.template)) {
        const input = el("textarea", { class: "short", placeholder: d[tag] || (tag === "SUBJECT" ? "Describe the subject" : "Optional: left out when empty") });
        input.value = values[tag] || "";
        input.addEventListener("input", () => { values[tag] = input.value; update(); });
        pane.append(el("label", { class: "tl" }, label(tag)), input);
        first = first || input;
      }
      const negIn = el("textarea", { class: "short", placeholder: "Optional" });
      negIn.value = values.__negative || "";
      negIn.addEventListener("input", () => { values.__negative = negIn.value; update(); });
      pane.append(el("label", { class: "tl" }, "Your negative prompt"), negIn);
      const n1 = el("span", { class: "ok" }), n2 = el("span", { class: "ok" });
      pane.append(el("label", { class: "tl" }, "Prompt"), out,
        el("div", { class: "row" }, el("button", { class: "act primary", type: "button", onclick: () => copy(out.value, n1) }, "Copy Prompt"), n1));
      pane.append(el("label", { class: "tl" }, "Negative prompt"), neg,
        el("div", { class: "row" }, el("button", { class: "act", type: "button", onclick: () => copy(neg.value, n2) }, "Copy Negative"), n2));
      if (s.notes) pane.append(el("div", { class: "note" }, s.notes));
      body.append(pane);
      dialog.append(el("button", { class: "close", type: "button", "aria-label": "Close", onclick: () => dialog.close() }, "×"), body);
      update();
      dialog.showModal();
      if (first) first.focus();
    }

    function renderCats() {
      const menu = document.getElementById("catsMenu");
      menu.textContent = "";
      const set = cats => { shownCats = new Set(cats); store.set("atelier.cats", [...shownCats]); renderCats(); renderList(); };
      menu.append(el("div", { class: "bar" },
        el("button", { class: "act", type: "button", onclick: () => set(allCats) }, "All"),
        el("button", { class: "act", type: "button", onclick: () => set([]) }, "None")));
      for (const cat of allCats) {
        const box = el("input", { type: "checkbox" });
        box.checked = shownCats.has(cat);
        box.addEventListener("change", () => { box.checked ? shownCats.add(cat) : shownCats.delete(cat); set([...shownCats]); });
        menu.append(el("label", {}, box, cat, el("span", { class: "n" }, String(styles.filter(s => (s.category || "Uncategorized") === cat).length))));
      }
    }

    function select(s) {
      selected = key(s);
      store.set("atelier.selected", selected);
      for (const c of document.querySelectorAll(".card.sel")) c.classList.remove("sel");
      const card = [...document.querySelectorAll(".card")].find(c => c.dataset.key === selected);
      if (card) card.classList.add("sel");
      openModal(s);
    }
    q.addEventListener("input", () => { store.set("atelier.query", q.value); renderList(); });
    const catsButton = document.getElementById("catsButton"), catsMenu = document.getElementById("catsMenu");
    catsButton.addEventListener("click", e => { e.stopPropagation(); catsMenu.hidden = !catsMenu.hidden; catsButton.setAttribute("aria-expanded", String(!catsMenu.hidden)); });
    catsMenu.addEventListener("click", e => e.stopPropagation());
    document.addEventListener("click", () => { catsMenu.hidden = true; catsButton.setAttribute("aria-expanded", "false"); });
    document.addEventListener("keydown", e => { if (e.key === "Escape") catsMenu.hidden = true; });
    // A click on the backdrop (outside the box) closes the modal.
    document.getElementById("modal").addEventListener("click", e => { if (e.target === e.currentTarget) e.currentTarget.close(); });
    renderCats();
    renderList();
  })();
  </script>
  </body>
  </html>
  """#
}

private nonisolated extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

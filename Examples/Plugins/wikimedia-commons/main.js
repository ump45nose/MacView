const USER_AGENT = "MacView-Wikimedia-Plugin/1.0 (https://github.com/ump45nose/MacView)";

plugin.commands["show-info"] = () => {
  const page = mv.page();
  if (!page) {
    mv.toast("当前没有打开图片");
    return;
  }
  const dims = (page.width && page.height) ? ` (${page.width}×${page.height})` : "";
  mv.toast(`${page.name || ""}${dims}`);
};

plugin.sources.wikimedia = {
  list(source, path) {
    if (Array.isArray(path) && path.length > 0) {
      return { entries: [] };
    }
    const query = (source && source.values && source.values.query || "").trim();
    if (!query) {
      throw new Error("缺少搜索词");
    }
    const apiURL =
      "https://commons.wikimedia.org/w/api.php?action=query&generator=search" +
      "&gsrnamespace=6&gsrlimit=50&prop=imageinfo&iiprop=url|size|timestamp|sha1&format=json" +
      "&gsrsearch=" + encodeURIComponent(query);
    const response = mv.http({
      url: apiURL,
      headers: { "User-Agent": USER_AGENT }
    });
    if (response.status < 200 || response.status >= 300) {
      throw new Error(`Wikimedia 请求失败（HTTP ${response.status}）`);
    }
    const payload = JSON.parse(response.body || "{}");
    const pages = payload && payload.query && payload.query.pages ? Object.values(payload.query.pages) : [];
    const entries = [];
    for (const item of pages) {
      const info = item && Array.isArray(item.imageinfo) ? item.imageinfo[0] : null;
      if (!info || !info.url) continue;
      const rawTitle = String(item.title || "");
      const name = rawTitle.startsWith("File:") ? rawTitle.slice(5) : rawTitle;
      if (!name) continue;
      const entry = {
        name,
        kind: "file",
        url: info.url,
        headers: { "User-Agent": USER_AGENT }
      };
      if (typeof info.size === "number") entry.size = info.size;
      if (typeof info.timestamp === "string") entry.modified = info.timestamp;
      if (typeof info.sha1 === "string") entry.etag = info.sha1;
      entries.push(entry);
    }
    return { entries };
  }
};

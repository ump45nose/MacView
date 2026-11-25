const isChinese = /^zh\b/i.test(navigator.language || "");

const strings = isChinese
  ? {
      noPage: "没有打开的页面",
      noWindow: "没有阅读窗口",
      sizeUnknown: "尺寸未知",
      nextPage: "下一页",
      placeholder: "记录本页笔记…",
      saving: "正在保存…",
      saved: "已保存",
      unsaved: "待保存…",
    }
  : {
      noPage: "No page open",
      noWindow: "No reader window",
      sizeUnknown: "Unknown size",
      nextPage: "Next Page",
      placeholder: "Write notes for this page…",
      saving: "Saving…",
      saved: "Saved",
      unsaved: "Unsaved…",
    };

const nameEl = document.getElementById("page-name");
const sizeEl = document.getElementById("page-size");
const nextBtn = document.getElementById("next-btn");
const noteInput = document.getElementById("note-input");
const saveStatusEl = document.getElementById("save-status");
const errorEl = document.getElementById("error-msg");

nextBtn.textContent = strings.nextPage;
noteInput.placeholder = strings.placeholder;

let currentKey = null;
let dirtyKey = null;
let dirtyText = "";
let saveTimer = null;
let loadSeq = 0;
let writeChain = Promise.resolve();

function storageKeyFor(page) {
  return page && page.location ? "note:" + page.location : null;
}

function showError(message) {
  if (!message) {
    errorEl.textContent = "";
    errorEl.hidden = true;
  } else {
    errorEl.textContent = String(message);
    errorEl.hidden = false;
  }
}

function enqueueWrite(key, text) {
  const op = () =>
    text.length > 0
      ? mv.storage.set(key, text)
      : mv.storage.remove(key);
  writeChain = writeChain.then(op, op).then(
    () => {
      if (currentKey === key && dirtyKey === null) {
        saveStatusEl.textContent = text.length > 0 ? strings.saved : "";
      }
    },
    (err) => {
      showError(err && err.message ? err.message : String(err));
    }
  );
  return writeChain;
}

function flushPendingSave() {
  if (saveTimer !== null) {
    clearTimeout(saveTimer);
    saveTimer = null;
  }
  if (dirtyKey === null) {
    return Promise.resolve();
  }
  const keyToSave = dirtyKey;
  const textToSave = dirtyText;
  dirtyKey = null;
  dirtyText = "";
  if (currentKey === keyToSave) {
    saveStatusEl.textContent = strings.saving;
  }
  return enqueueWrite(keyToSave, textToSave);
}

async function refreshPage(hasWindow = true) {
  flushPendingSave();
  const seq = ++loadSeq;
  showError("");

  if (!hasWindow) {
    currentKey = null;
    nameEl.textContent = strings.noWindow;
    sizeEl.textContent = "";
    noteInput.value = "";
    noteInput.disabled = true;
    nextBtn.disabled = true;
    saveStatusEl.textContent = "";
    return;
  }

  let page = null;
  try {
    page = await mv.page();
  } catch (err) {
    if (seq !== loadSeq) return;
    showError(err && err.message ? err.message : String(err));
    return;
  }
  if (seq !== loadSeq) return;

  if (!page || !page.location) {
    currentKey = null;
    nameEl.textContent = strings.noPage;
    sizeEl.textContent = "";
    noteInput.value = "";
    noteInput.disabled = true;
    nextBtn.disabled = true;
    saveStatusEl.textContent = "";
    return;
  }

  const key = storageKeyFor(page);
  const pageChanged = key !== currentKey;
  currentKey = key;
  nameEl.textContent = page.name || "";
  if (typeof page.width === "number" && typeof page.height === "number") {
    sizeEl.textContent = `${page.width} × ${page.height}`;
  } else {
    sizeEl.textContent = strings.sizeUnknown;
  }
  nextBtn.disabled = false;
  noteInput.disabled = false;

  if (pageChanged) {
    noteInput.value = "";
    saveStatusEl.textContent = "";
  }

  // 等待之前的保存写入落盘后再读，避免快速切回同一页时读到旧值。
  await writeChain;
  if (seq !== loadSeq || currentKey !== key) return;

  let saved = null;
  try {
    saved = await mv.storage.get(key);
  } catch (err) {
    if (seq !== loadSeq) return;
    showError(err && err.message ? err.message : String(err));
    return;
  }
  if (seq !== loadSeq || currentKey !== key) return;
  if (dirtyKey === key) return;

  const text = typeof saved === "string" ? saved : "";
  noteInput.value = text;
  saveStatusEl.textContent = text.length > 0 ? strings.saved : "";
}

noteInput.addEventListener("input", () => {
  if (!currentKey) return;
  if (dirtyKey === null) {
    dirtyKey = currentKey;
  }
  dirtyText = noteInput.value;
  saveStatusEl.textContent = strings.unsaved;
  if (saveTimer !== null) {
    clearTimeout(saveTimer);
  }
  saveTimer = setTimeout(() => {
    flushPendingSave();
  }, 500);
});

nextBtn.addEventListener("click", async () => {
  showError("");
  flushPendingSave();
  try {
    await mv.command("page.next");
  } catch (err) {
    showError(err && err.message ? err.message : String(err));
  }
});

window.addEventListener("pagehide", () => {
  flushPendingSave();
});

async function init() {
  await mv.on("pageChanged", () => {
    refreshPage(true);
  });
  await mv.on("bookOpened", () => {
    refreshPage(true);
  });
  await mv.on("targetChanged", (payload) => {
    const hasWindow = !payload || payload.hasWindow !== false;
    refreshPage(hasWindow);
  });
  await refreshPage(true);
}

init();

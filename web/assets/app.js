(() => {
  "use strict";

  // Frame-buster. Заголовок X-Frame-Options busybox httpd к статике не
  // добавляет, а frame-ancestors внутри <meta> CSP браузер по спецификации
  // игнорирует. Без этого панель со всеми её кнопками можно подложить в
  // невидимый iframe на чужой странице и кликать за пользователя.
  if (window.self !== window.top) {
    document.documentElement.replaceChildren();
    try { window.top.location = window.self.location; } catch { /* другой origin */ }
    return;
  }

  const $ = (id) => document.getElementById(id);
  const all = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const decode = (value = "") => {
    try {
      const bytes = Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
      return new TextDecoder().decode(bytes);
    } catch {
      return "";
    }
  };
  const decodeHeader = (value = "") => {
    const decoded = decode(value);
    if (!decoded.startsWith("base64:")) return decoded;
    try {
      const bytes = Uint8Array.from(atob(decoded.slice(7)), (character) => character.charCodeAt(0));
      return new TextDecoder().decode(bytes);
    } catch {
      return decoded;
    }
  };
  const escapeHtml = (value) => String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[character]);
  const icon = (name) => `<svg aria-hidden="true"><use href="#i-${name}"></use></svg>`;
  const enabled = (value) => value === true || value === 1 || value === "1" || value === "true";

  let model = { profiles: [], configs: [] };
  let cardsFingerprint = "";
  let settingsFingerprint = "";
  let refreshPending = false;
  let toastTimer;
  let pollTimer;
  let pollFailures = 0;
  const ui = {
    page: "subscriptions",
    settingsTab: "requests",
    editorProfileId: "",
    editorDirty: false,
    deleteProfileId: "",
    settingsDirty: false,
    themeDraft: undefined,
    accentDraft: undefined,
    selectingProfileId: "",
    pendingConfig: null,
    busy: new Set(),
    probes: new Map(),
  };

  function toast(message, tone = "info") {
    const node = $("toast");
    node.textContent = message;
    node.classList.toggle("error", tone === "error");
    node.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => node.classList.remove("show"), tone === "error" ? 4800 : 2800);
  }

  async function api(action = "status", data) {
    const options = data === undefined ? {} : {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(data),
    };
    const response = await fetch(`/cgi-bin/api?action=${encodeURIComponent(action)}`, options);
    const text = await response.text();
    let result;
    try {
      result = JSON.parse(text);
    } catch {
      throw new Error(response.ok ? "API вернул некорректный ответ" : `HTTP ${response.status}`);
    }
    if (!response.ok || !result.ok) throw new Error(result.error || `HTTP ${response.status}`);
    return result;
  }

  function setBusy(key, enabled) {
    if (enabled) ui.busy.add(key);
    else ui.busy.delete(key);
    renderActionStates();
    cardsFingerprint = "";
    if ($("subscription-list")) renderSubscriptions();
  }

  async function perform(key, action) {
    if (ui.busy.has(key)) return;
    setBusy(key, true);
    try {
      await action();
    } catch (error) {
      toast(error.message || String(error), "error");
    } finally {
      setBusy(key, false);
    }
  }

  function profileById(id) {
    return model.profiles.find((profile) => profile.id === id) || null;
  }

  function activeProfile() {
    return profileById(model.active_profile_id);
  }

  function profileName(profile) {
    if (!profile) return "Профиль не выбран";
    const displayName = decodeHeader(profile.display_name_b64);
    const providerTitle = Number(profile.use_provider_title ?? 1) !== 0 ? decodeHeader(profile.title_b64) : "";
    return displayName || providerTitle || decode(profile.name_b64) || profile.id;
  }

  function profileUrl(profile) {
    return profile ? decode(profile.url_b64) : "";
  }

  function profileError(profile) {
    return profile ? decode(profile.error_b64) : "";
  }

  function profileHealth(profile) {
    if (profile.id === ui.selectingProfileId) return { className: "warning busy", label: "Переключение..." };
    const active = profile.id === model.active_profile_id;
    if (profile.status === "working" || profile.refresh_state === "working") {
      const stages = { queued: "В очереди...", download: "Загрузка подписки...", metadata: "Чтение заголовков...", geodata: "Загрузка geodata...", validation: "Проверка конфигурации...", build: "Подготовка конфигурации...", install: "Установка...", apply: "Применение...", ready: "Готово" };
      return { className: "warning busy", label: stages[profile.refresh_stage] || decode(profile.status_message_b64) || "Обновление..." };
    }
    if (enabled(profile.fail_closed)) return { className: "error", label: "Доступ ограничен" };
    if (enabled(profile.using_previous_config)) return { className: "error", label: "Обновление отклонено" };
    if (profileError(profile)) return profile.config_present
      ? { className: "error", label: "Обновление отклонено" }
      : { className: "error", label: "Ошибка конфигурации" };
    if (!profileUrl(profile)) return { className: "warning", label: "URL не настроен" };
    if (active && model.running) return { className: "good", label: "Xray работает" };
    if (active && model.run_enabled) return { className: "warning", label: "Ожидание запуска" };
    if (profile.config_present) return { className: "good", label: "Конфигурация проверена" };
    if (profile.source_present) return { className: "good", label: "JSON получен" };
    return { className: "", label: "Не загружалась" };
  }

  function profileDiagnostic(profile) {
    const rows = [];
    const validation = decode(profile.validation_b64);
    const error = profileError(profile);
    const httpLine = decode(profile.http_status_line_b64);
    if (profile.refresh_action) rows.push(`Действие: ${profile.refresh_action}`);
    if (profile.refresh_stage) rows.push(`Этап: ${profile.refresh_stage}`);
    if (profile.refresh_state) rows.push(`Состояние: ${profile.refresh_state}`);
    if (httpLine) rows.push(`HTTP: ${httpLine}`);
    else if (Number(profile.http_status)) rows.push(`HTTP: ${profile.http_status}`);
    if (Number(profile.response_bytes)) rows.push(`Ответ: ${formatBytes(profile.response_bytes)}`);
    if (validation) rows.push(`Проверка: ${validation}`);
    if (error) rows.push(`Ошибка: ${error}`);
    rows.push(`Конфигурация: ${enabled(profile.configuration_valid) ? "валидна" : "не готова"}`);
    if (enabled(profile.using_previous_config)) rows.push("Запуск: сохранена предыдущая корректная конфигурация");
    if (enabled(profile.fail_closed)) rows.push("Трафик заблокирован из-за ограничения провайдера или пустой подписки");
    if (profile.policy_status) rows.push(`Политика: ${profile.policy_status}`);
    if (Number(profile.config_count) >= 0) rows.push(`Конфигураций: ${Number(profile.config_count) || 0}`);
    if (Number(profile.config_count) > 0 && Number.isInteger(Number(profile.selected_config_index)) && Number(profile.selected_config_index) >= 0) rows.push(`Выбранный конфиг: ${Number(profile.selected_config_index) + 1}`);
    if (profile.final_version) rows.push(`Версия конфигурации: ${profile.final_version}`);
    const sourceTime = formatDate(profile.source_mtime);
    const finalTime = formatDate(profile.final_mtime);
    const started = formatDate(profile.started_at);
    const finished = formatDate(profile.finished_at);
    const statusUpdated = formatDate(profile.status_updated_at);
    if (sourceTime) rows.push(`Исходный JSON: ${sourceTime}`);
    if (finalTime) rows.push(`Выбранный JSON: ${finalTime}`);
    if (started) rows.push(`Начало: ${started}`);
    if (finished) rows.push(`Завершение: ${finished}`);
    if (statusUpdated) rows.push(`Статус обновлён: ${statusUpdated}`);
    return rows.join("\n");
  }

  function profilePolicyEntries(profile) {
    return [
      ["HWID активен", decode(profile.hwid_active_b64)],
      ["HWID не поддерживается", decode(profile.hwid_unsupported_b64)],
      ["Лимит HWID достигнут", decode(profile.hwid_max_b64)],
      ["Лимит устройств", decode(profile.hwid_limit_b64)],
      ["Пополнение", decode(profile.refill_b64)],
    ].filter(([, value]) => value).map(([label, value]) => `${label}: ${value}`);
  }

  function pluralProfiles(count) {
    const lastTwo = count % 100;
    const last = count % 10;
    if (lastTwo >= 11 && lastTwo <= 14) return "профилей";
    if (last === 1) return "профиль";
    if (last >= 2 && last <= 4) return "профиля";
    return "профилей";
  }

  function formatDate(epoch) {
    const value = Number(epoch);
    if (!Number.isFinite(value) || value <= 0) return "";
    const date = new Date(value > 100000000000 ? value : value * 1000);
    return Number.isNaN(date.getTime()) ? "" : date.toLocaleString("ru-RU");
  }

  function formatUpdated(epoch) {
    const value = Number(epoch) * 1000;
    if (!value) return "не обновлялась";
    const seconds = Math.max(0, Math.round((Date.now() - value) / 1000));
    if (seconds < 60) return "только что";
    if (seconds < 3600) return `${Math.floor(seconds / 60)} мин. назад`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)} ч. назад`;
    return formatDate(epoch);
  }

  function formatInterval(seconds) {
    const value = Math.max(60, Number(seconds) || 3600);
    if (value % 86400 === 0) return `${value / 86400} дн.`;
    if (value % 3600 === 0) return `${value / 3600} ч.`;
    return `${Math.round(value / 60)} мин.`;
  }

  function formatBytes(value) {
    let amount = Number(value);
    if (!Number.isFinite(amount) || amount < 0) return "";
    const units = ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"];
    let unit = 0;
    while (amount >= 1024 && unit < units.length - 1) {
      amount /= 1024;
      unit += 1;
    }
    const digits = amount >= 100 || unit === 0 ? 0 : amount >= 10 ? 1 : 2;
    return `${amount.toLocaleString("ru-RU", { maximumFractionDigits: digits })} ${units[unit]}`;
  }

  function parseUserInfo(raw) {
    const values = {};
    raw.split(/[;,]/).forEach((entry) => {
      const separator = entry.indexOf("=");
      if (separator < 1) return;
      values[entry.slice(0, separator).trim().toLowerCase()] = entry.slice(separator + 1).trim();
    });
    const upload = Number(values.upload);
    const download = Number(values.download);
    const total = Number(values.total);
    const used = (Number.isFinite(upload) ? upload : 0) + (Number.isFinite(download) ? download : 0);
    return {
      used: Number.isFinite(upload) || Number.isFinite(download) ? used : null,
      total: Number.isFinite(total) && total > 0 ? total : null,
      expiry: formatDate(values.expire),
    };
  }

  function safeHttpUrl(value) {
    try {
      const url = new URL(value.trim());
      return (url.protocol === "http:" || url.protocol === "https:") && !url.username && !url.password ? url.href : "";
    } catch {
      return "";
    }
  }

  const requiredHeaders = [
    ["x-hwid", "RouterOS-Solomon"],
    ["x-device-os", "RouterOS"],
    ["x-ver-os", "7"],
    ["x-device-model", "MikroTik"],
    ["user-agent", "Happ/4.0.1/Android/35"],
  ];

  // Выключенный заголовок хранится той же строкой с ведущей решёткой: значение
  // не теряется, и галочку можно вернуть, ничего не набирая заново.
  function parseHeaders(raw) {
    return String(raw || "").split(/\r?\n/).map((line) => {
      const enabled = !/^\s*#/.test(line);
      const body = enabled ? line : line.replace(/^\s*#/, "");
      const separator = body.indexOf(":");
      if (separator < 1) return null;
      return [body.slice(0, separator).trim(), body.slice(separator + 1).trim(), enabled];
    }).filter(Boolean);
  }

  // Флаг в начале имени конфигурации: либо пара regional indicator (🇱🇻), либо
  // чёрный флаг с тегами (🏴󠁧󠁢󠁳󠁣󠁴󠁿). Он занимает место номера строки, а имя
  // показывается уже без него — иначе флаг и цифра стоят рядом и дублируют
  // друг друга.
  const FLAG_PREFIX = /^(?:[\u{1F1E6}-\u{1F1FF}]{2}|\u{1F3F4}[\u{E0060}-\u{E007F}]+)/u;

  function splitFlag(name) {
    const text = String(name || "");
    const match = text.match(FLAG_PREFIX);
    if (!match) return { flag: "", name: text };
    return { flag: match[0], name: text.slice(match[0].length).replace(/^[\s·—-]+/, "") };
  }

  function headerRow(name = "", value = "", locked = false, enabled = true) {
    return `<div class="header-row"><label class="header-toggle" title="Отправлять этот заголовок"><input type="checkbox" data-header-enabled${enabled ? " checked" : ""}><i></i></label><input type="text" data-header-key value="${escapeHtml(name)}" placeholder="X-Header" pattern="[A-Za-z0-9-]+" maxlength="128"${locked ? " readonly" : ""}><input type="text" data-header-value value="${escapeHtml(value)}" placeholder="Значение" maxlength="2048">${locked ? `<span class="header-lock" title="Обязательный заголовок">${icon("lock")}</span>` : `<button class="icon-button danger" type="button" data-remove-header title="Удалить заголовок">${icon("trash")}</button>`}</div>`;
  }

  function renderHeaders(containerId, raw, includeRequired = false) {
    const parsed = parseHeaders(raw);
    const requiredNames = new Set(requiredHeaders.map(([name]) => name));
    const headers = includeRequired
      ? requiredHeaders.map(([name, fallback]) => parsed.find(([key]) => key.toLowerCase() === name) || [name, fallback, true]).concat(parsed.filter(([key]) => !requiredNames.has(key.toLowerCase())))
      : parsed;
    $(containerId).innerHTML = headers.map(([name, value, enabled]) => headerRow(name, value, includeRequired && requiredNames.has(name.toLowerCase()), enabled !== false)).join("");
  }

  function appendHeader(containerId) {
    $(containerId).insertAdjacentHTML("beforeend", headerRow());
    const rows = all(".header-row", $(containerId));
    rows.at(-1)?.querySelector("[data-header-key]")?.focus();
  }

  function collectHeaders(containerId) {
    return all(".header-row", $(containerId)).map((row) => {
      const name = row.querySelector("[data-header-key]").value.trim();
      const value = row.querySelector("[data-header-value]").value.trim();
      const enabled = row.querySelector("[data-header-enabled]")?.checked !== false;
      return name ? `${enabled ? "" : "#"}${name}: ${value}` : "";
    }).filter(Boolean).join("\n");
  }

  function showPage(pageName) {
    ui.page = pageName;
    all("[data-page-link]").forEach((button) => button.classList.toggle("active", button.dataset.pageLink === pageName));
    all("[data-page]").forEach((page) => page.classList.toggle("active", page.dataset.page === pageName));
  }

  // ── Тема ────────────────────────────────────────────────────
  // Выбранное применяется сразу, чтобы решение принималось глядя на результат,
  // а сохраняется вместе с остальными настройками по кнопке «Сохранить».
  const theme = window.RemnaTheme;

  function currentTheme() {
    return ui.themeDraft ?? (theme.isTheme(model.ui_theme) ? model.ui_theme : "auto");
  }

  function currentAccent() {
    const draft = ui.accentDraft;
    if (draft !== undefined) return draft;
    return theme.isAccent(model.ui_accent) ? model.ui_accent : "";
  }

  function applyCurrentTheme() {
    theme.applyTheme(currentTheme(), currentAccent());
  }

  function renderThemeControls() {
    const selectedTheme = currentTheme();
    const selectedAccent = currentAccent();
    $("theme-grid").innerHTML = theme.THEMES.map((entry) => {
      const resolved = theme.resolveTheme(entry.id);
      const checked = entry.id === selectedTheme;
      return `<button class="theme-card" type="button" role="radio" aria-checked="${checked ? "true" : "false"}" data-theme-id="${escapeHtml(entry.id)}" data-theme="${escapeHtml(resolved)}"><span class="theme-preview"><i></i><span><em></em><em></em></span></span><strong>${escapeHtml(entry.label)}</strong></button>`;
    }).join("");
    // Цвет проставляется через CSSOM, а не атрибутом style: страница отдаётся с
    // CSP `style-src 'self'`, поэтому инлайн-стиль браузер отбрасывает и
    // образцы остаются бесцветными.
    $("accent-presets").innerHTML = theme.ACCENT_PRESETS.map((colour) =>
      `<button type="button" data-accent="${escapeHtml(colour)}" aria-pressed="${colour.toLowerCase() === selectedAccent.toLowerCase() ? "true" : "false"}" title="${escapeHtml(colour)}" aria-label="Акцент ${escapeHtml(colour)}"></button>`).join("");
    all("[data-accent]", $("accent-presets")).forEach((button) => { button.style.background = button.dataset.accent; });
    $("accent-color").value = selectedAccent || "#9bd45a";
    $("accent-reset").disabled = !selectedAccent;
  }

  function setTheme(themeId) {
    ui.themeDraft = themeId;
    ui.settingsDirty = true;
    applyCurrentTheme();
    renderThemeControls();
  }

  function setAccent(accent) {
    ui.accentDraft = accent;
    ui.settingsDirty = true;
    applyCurrentTheme();
    renderThemeControls();
  }

  function showSettingsTab(tabName) {
    ui.settingsTab = tabName;
    all("[data-settings-tab]").forEach((button) => button.classList.toggle("active", button.dataset.settingsTab === tabName));
    all("[data-settings-panel]").forEach((panel) => panel.classList.toggle("active", panel.dataset.settingsPanel === tabName));
  }

  function renderRuntime() {
    const profile = activeProfile();
    const running = Boolean(model.running && model.run_enabled);
    const waiting = Boolean(model.run_enabled && !model.running);
    const dot = $("sidebar-core-dot");
    dot.className = running ? "running" : waiting ? "waiting" : "";
    $("sidebar-core-title").textContent = running ? "Xray работает" : waiting ? "Xray запускается" : "Xray остановлен";
    $("sidebar-active-profile").textContent = profileName(profile);
    $("nav-profile-count").textContent = String(model.profiles.length);
    $("subscriptions-subtitle").textContent = `${model.profiles.length} ${pluralProfiles(model.profiles.length)}`;
    $("open-active-runtime").disabled = !profile || !profile.config_present;
    $("xray-version").textContent = model.version || "Xray";
    $("network-firewall-backend").textContent = model.firewall_backend || "Не определён";
    $("network-active-interface").textContent = [model.active_interface, model.active_interface_cidr].filter(Boolean).join(" · ") || "Не найден";

    const events = decode(model.events_b64);
    const eventsViewer = $("runtime-events");
    const wasAtBottom = eventsViewer.scrollHeight - eventsViewer.scrollTop - eventsViewer.clientHeight < 24;
    const nextEvents = events || "Событий пока нет.";
    if (eventsViewer.value !== nextEvents) eventsViewer.value = nextEvents;
    if (wasAtBottom) eventsViewer.scrollTop = eventsViewer.scrollHeight;
    $("runtime-events-state").textContent = events ? "Последние 100 событий" : "Событий пока нет";
    const active = profile;
    const result = !active ? "Нет профиля" : enabled(active.fail_closed) ? "Трафик заблокирован" : enabled(active.using_previous_config) ? "Предыдущая конфигурация" : active.config_present ? "Конфигурация принята" : "Конфигурация не создана";
    $("events-diagnostic-summary").innerHTML = `<span><small>Профиль</small><b>${escapeHtml(profileName(active))}</b></span><span><small>Этап</small><b>${escapeHtml(active?.refresh_stage || active?.status || "idle")}</b></span><span><small>HTTP / ответ</small><b>${active && Number(active.http_status) ? `HTTP ${escapeHtml(active.http_status)}${Number(active.response_bytes) ? ` · ${escapeHtml(formatBytes(active.response_bytes))}` : ""}` : "Нет данных"}</b></span><span><small>Результат</small><b>${escapeHtml(result)}</b></span>`;
  }

  function renderSubscriptions() {
    const fingerprint = JSON.stringify({
      active: model.active_profile_id,
      running: model.running,
      runEnabled: model.run_enabled,
      selecting: ui.selectingProfileId,
      pendingConfig: ui.pendingConfig,
      profiles: model.profiles,
      configs: model.configs,
      busy: Array.from(ui.busy).sort(),
      probes: Array.from(ui.probes.entries()),
      storedProbes: model.probes,
    });
    if (fingerprint === cardsFingerprint) return;
    cardsFingerprint = fingerprint;
    // Список пересобирается целиком, а во время обновления подписки опрос идёт
    // раз в 800 мс — без этого фокус слетал с кнопки под курсором, и клик
    // попадал уже по новому узлу. Запоминаем, что было в фокусе, и возвращаем.
    const focused = document.activeElement;
    const focusedKey = focused && $("subscription-list")?.contains(focused)
      ? [focused.dataset.configIndex, focused.dataset.probeIndex, focused.dataset.profileAction, focused.className].join("|")
      : "";
    const restoreFocus = () => {
      if (!focusedKey) return;
      const match = all("button", $("subscription-list")).find((button) =>
        [button.dataset.configIndex, button.dataset.probeIndex, button.dataset.profileAction, button.className].join("|") === focusedKey);
      if (match && !match.disabled) match.focus({ preventScroll: true });
    };
    $("subscription-list").innerHTML = model.profiles.map((profile) => {
      const active = profile.id === model.active_profile_id;
      const health = profileHealth(profile);
      const working = profile.status === "working";
      const hasUrl = Boolean(profileUrl(profile));
      const error = profileError(profile);
      const response = [Number(profile.http_status) ? `HTTP ${profile.http_status}` : "", Number(profile.response_bytes) ? formatBytes(profile.response_bytes) : ""].filter(Boolean).join(" · ")
        || (profile.config_present ? "Выбранный JSON готов" : profile.source_present ? "Исходный JSON сохранён" : "Нет данных");
      const restriction = decode(profile.restriction_b64);
      const restricted = enabled(profile.restricted) || enabled(profile.fail_closed) || Boolean(restriction);
      const policyEntries = profilePolicyEntries(profile);
      const warning = restricted ? `<aside class="subscription-provider-warning">${icon("alert")}<div><strong>${enabled(profile.fail_closed) ? "Трафик заблокирован политикой подписки" : "Ограничение подписки"}</strong><p>${escapeHtml(restriction || "Провайдер ограничил доступ для этой подписки.")}</p>${policyEntries.length ? `<div class="subscription-provider-messages">${policyEntries.map((entry) => `<span>${escapeHtml(entry)}</span>`).join("")}</div>` : ""}</div></aside>` : "";
      const diagnostic = profileDiagnostic(profile);
      return `<article class="subscription-card${active ? " active" : ""}">
        <button class="subscription-select" type="button" data-profile-select="${escapeHtml(profile.id)}" aria-pressed="${active ? "true" : "false"}"${active ? " disabled" : ""}>${active ? "Выбранная подписка" : `Выбрать подписку ${escapeHtml(profileName(profile))}`}</button>
        <div class="subscription-main">
          <span class="subscription-icon">${icon("bookmark")}</span>
          <div class="subscription-details">
            <div class="subscription-title"><strong>${escapeHtml(profileName(profile))}</strong>${active ? "<mark>выбрана</mark>" : ""}</div>
            <p>${escapeHtml(profileUrl(profile) || "URL не задан")}</p>
            <div class="subscription-meta"><span>${icon("clock")}<time>${escapeHtml(formatUpdated(profile.fetched_at))}</time></span><span>${icon("refresh")}авто: ${escapeHtml(formatInterval(profile.effective_refresh_seconds || profile.refresh_seconds))}</span><span>${icon("file")}${Number(profile.config_count) || 0} конфиг.</span></div>
          </div>
          <div class="subscription-actions">
            <span class="subscription-runtime-controls" aria-label="Управление Xray">
              <button class="icon-button runtime-start" type="button" data-profile-action="start" data-profile-id="${escapeHtml(profile.id)}" title="${active ? "Запустить Xray" : "Сначала выберите подписку"}"${active && hasUrl && !model.run_enabled && !working ? "" : " disabled"}>${icon("play")}</button>
              <button class="icon-button runtime-stop" type="button" data-profile-action="stop" data-profile-id="${escapeHtml(profile.id)}" title="${active ? "Остановить Xray" : "Сначала выберите подписку"}"${active && model.run_enabled ? "" : " disabled"}>${icon("stop")}</button>
            </span>
            <button class="icon-button" type="button" data-profile-action="edit" data-profile-id="${escapeHtml(profile.id)}" title="Настройки">${icon("settings")}</button>
            <button class="icon-button${working ? " loading" : ""}" type="button" data-profile-action="refresh" data-profile-id="${escapeHtml(profile.id)}" title="Обновить сейчас"${hasUrl && !working ? "" : " disabled"}>${icon("refresh")}</button>
            <button class="icon-button" type="button" data-profile-action="source" data-profile-id="${escapeHtml(profile.id)}" title="Полученный JSON">${icon("file")}</button>
            <button class="icon-button danger" type="button" data-profile-action="delete" data-profile-id="${escapeHtml(profile.id)}" title="${active ? "Активную подписку удалить нельзя" : "Удалить"}"${active ? " disabled" : ""}>${icon("trash")}</button>
          </div>
        </div>
        ${active ? renderConfigRows(profile) : ""}
        <footer class="subscription-footer"><span class="subscription-health ${health.className}"><i></i>${escapeHtml(health.label)}</span><span class="subscription-response">${escapeHtml(response)}</span><code>${escapeHtml(profile.id)}</code></footer>
        ${warning}
        ${(error || enabled(profile.using_previous_config) || enabled(profile.fail_closed) || profile.refresh_state === "error") ? `<details class="subscription-diagnostic" data-profile-diagnostics><summary>Диагностика последнего обновления</summary><pre>${escapeHtml(diagnostic)}</pre></details>` : ""}
      </article>`;
    }).join("");
    $("subscription-list").classList.toggle("hidden", model.profiles.length === 0);
    $("subscription-empty").classList.toggle("hidden", model.profiles.length !== 0);
    restoreFocus();
  }

  function renderConfigRows(profile) {
    const configs = Array.isArray(model.configs) ? model.configs : [];
    if (!configs.length) return profile.source_present ? `<div class="subscription-configs"><div class="config-list-empty">Конфигурации появятся после проверки подписки</div></div>` : "";
    const probeAllBusy = ui.busy.has(`probe-all:${profile.id}`);
    const probeRunning = Array.from(ui.probes.entries()).some(([key, probe]) => key.startsWith(`${profile.id}:`) && probe.pending);
    return `<div class="subscription-configs"><div class="config-list-heading"><span>Конфигурации подписки <small>${configs.length}</small></span><button class="config-probe-all${probeAllBusy ? " loading" : ""}" type="button" data-probe-all title="Проверить все конфигурации одним экземпляром Xray"${probeAllBusy || probeRunning ? " disabled" : ""}>${icon("activity")}<span>${probeAllBusy ? "Проверка" : "Проверить все"}</span></button></div><div class="config-list">${configs.map((config) => {
      const pending = pendingSelectionFor(profile);
      const selectedFingerprint = pending ? pending.fingerprint : profile.selected_config_fingerprint;
      const selectedIndex = pending ? pending.index : profile.selected_config_index;
      const selected = selectedFingerprint
        ? config.fingerprint === selectedFingerprint
        : Number(config.index) === Number(selectedIndex);
      const description = config.description && config.description !== config.name ? `<small>${escapeHtml(config.description)}</small>` : "";
      const probeKey = `${profile.id}:${config.fingerprint || config.index}`;
      // Локальное состояние важнее сохранённого: пока проверка идёт, показываем
      // именно её, а не прошлый результат из контейнера.
      const probe = ui.probes.get(probeKey) || (model.probes || {})[config.fingerprint] || undefined;
      const alive = Number(probe?.alive);
      const total = Number(probe?.total);
      const delay = probe?.delay_ms == null ? Number.NaN : Number(probe.delay_ms);
      const hasResult = probe && !probe.pending && !probe.error && (Number.isFinite(delay) || Number.isFinite(alive));
      let probeLabel = "HTTP";
      let probeClass = "";
      if (probe?.pending) {
        probeLabel = "…";
        probeClass = " pending";
      } else if (probe?.error) {
        probeLabel = "ошибка";
        probeClass = " unreachable";
      } else if (hasResult) {
        // Проверка останавливается на первом живом outbound, поэтому счётчик
        // вида 1/1 ничего не сообщает и в подписи не показывается.
        const reachable = Number.isFinite(delay) && delay >= 0;
        probeLabel = reachable ? `${Math.round(delay)} ms` : "нет связи";
        probeClass = reachable ? " reachable" : " unreachable";
      }
      const probeMethod = String(probe?.method || model.xray_probe_http_method || "HEAD").toUpperCase();
      const probeSource = probe?.source ? ` · источник: ${probe.source}` : "";
      const probeTitle = probe?.error || `HTTP ${probeMethod} через Xray${probeSource}`;
      const switching = Boolean(pending) && selected;
      const rowState = switching ? "переключение..." : selected ? "выбрана" : "выбрать";
      const { flag, name: configName } = splitFlag(config.name);
      const badge = flag
        ? `<span class="config-row-index flag" title="Конфигурация ${Number(config.index) + 1}">${escapeHtml(flag)}</span>`
        : `<span class="config-row-index">${Number(config.index) + 1}</span>`;
      return `<div class="config-row${selected ? " selected" : ""}${switching ? " switching" : ""}"><button class="config-row-select" type="button" data-config-index="${Number(config.index)}" aria-pressed="${selected ? "true" : "false"}"${selected || pending || ui.busy.has("config") ? " disabled" : ""}>${badge}<span class="config-row-copy"><strong>${escapeHtml(configName || `Конфигурация ${Number(config.index) + 1}`)}</strong>${description}</span><span class="config-row-state">${rowState}</span></button><button class="config-probe${probeClass}" type="button" data-probe-index="${Number(config.index)}" title="${escapeHtml(probeTitle)}"${probeRunning || probeAllBusy ? " disabled" : ""}>${icon("activity")}<span>${escapeHtml(probeLabel)}</span></button></div>`;
    }).join("")}</div><p class="config-probe-note">«Проверить все» поднимает один экземпляр Xray на всю подписку и опрашивает outbound параллельно. Проверка отдельной строки поднимает свой экземпляр рядом с работающим ядром.</p></div>`;
  }

  function settingsStateSignature() {
    return JSON.stringify([
      model.global_headers_b64, model.listener_mode, model.effective_listener_mode, model.firewall_backend, model.redir_port, model.tproxy_port,
      model.dns_override_enabled, model.dns_override,
      model.inbound_strip_socks, model.inbound_strip_http,
      model.local_socks_enabled, model.local_socks_port, model.local_socks_user, model.local_socks_has_pass,
      model.local_http_enabled, model.local_http_port, model.local_http_user, model.local_http_has_pass,
      model.log_level, model.xray_log_error, model.xray_log_access, model.xray_log_dns, model.xray_log_mask_address,
      model.network_qdisc, model.network_disable_ipv6, model.network_disable_multicast,
      model.network_ct_established, model.network_ct_unacknowledged, model.network_ct_syn_sent,
      model.network_ct_syn_recv, model.network_ct_fin_wait, model.network_ct_close_wait,
      model.network_ct_last_ack, model.network_ct_time_wait, model.network_ct_close,
      model.network_ct_udp_stream, model.xray_sniffing_enabled, model.xray_sniffing_route_only,
      model.xray_probe_url, model.xray_probe_timeout_seconds, model.xray_probe_http_method,
      model.geodata_storage, model.geodata_asset_dir, model.geodata_asset_count,
      model.geodata_total_bytes, model.geodata_last_update, model.geodata_warning,
      model.ui_theme, model.ui_accent,
    ]);
  }

  function updateListenerDescription() {
    const selected = document.querySelector('input[name="listener-mode"]:checked')?.value || "auto";
    const nft = model.firewall_backend === "nftables";
    // auto здесь не режим, а «ещё не разобрано»: принимать его за фактический
    // означало бы обещать TUN там, где ядро прекрасно умеет TPROXY.
    const reported = model.effective_listener_mode;
    const effective = reported && reported !== "auto" ? reported : (nft ? "redir-tproxy" : "redir-tun");
    const effectiveUsesTproxy = effective === "tproxy" || effective === "redir-tproxy";
    $("auto-mode-description").textContent = `Фактически: ${effective}`;
    const descriptions = {
      auto: effectiveUsesTproxy ? "Автоматический режим выберет REDIR TCP + TPROXY UDP." : "Автоматический режим выберет REDIR TCP + TUN UDP.",
      "redir-tun": "TCP перехватывается REDIR, UDP проходит через TUN Xray.",
      "redir-tproxy": "TCP перехватывается REDIR, UDP проходит через TPROXY.",
      tproxy: "TCP и UDP проходят через единый TPROXY inbound.",
    };
    $("listener-mode-note").textContent = `${descriptions[selected]} Текущий эффективный режим: ${effective}.`;
    all("[data-port-field]").forEach((field) => {
      const kind = field.dataset.portField;
      const used = kind === "redir"
        ? selected !== "tproxy" && !(selected === "auto" && effective === "tproxy")
        : selected === "tproxy" || selected === "redir-tproxy" || (selected === "auto" && effectiveUsesTproxy);
      field.classList.toggle("unused", !used);
    });
  }

  function updateSniffingFields() {
    $("xray-sniffing-route-only").disabled = !$("xray-sniffing-enabled").checked;
  }

  function updateDnsOverrideFields() {
    all("[data-dns-override]").forEach((field) => field.classList.toggle("hidden", !$("dns-override-enabled").checked));
  }

  function updateLocalInboundFields() {
    all("[data-local-socks]").forEach((field) => field.classList.toggle("hidden", !$("local-socks-enabled").checked));
    all("[data-local-http]").forEach((field) => field.classList.toggle("hidden", !$("local-http-enabled").checked));
  }

  function updateGeodataFields() {
    const storage = document.querySelector('input[name="geodata-storage"]:checked')?.value || "memory";
    const defaultDirectory = storage === "persistent" ? "/etc/xray/remnasub/geodata" : "/dev/shm/xray-remnasub/geodata";
    $("geodata-memory-warning").classList.toggle("hidden", storage !== "memory");
    $("geodata-asset-dir").textContent = model.geodata_asset_dir || defaultDirectory;

    const count = Number(model.geodata_asset_count);
    const hasCount = model.geodata_asset_count !== undefined && model.geodata_asset_count !== null && model.geodata_asset_count !== "" && Number.isFinite(count) && count >= 0;
    $("geodata-asset-count").textContent = hasCount ? count.toLocaleString("ru-RU") : "Нет данных";

    const totalBytes = Number(model.geodata_total_bytes);
    const hasTotalBytes = model.geodata_total_bytes !== undefined && model.geodata_total_bytes !== null && model.geodata_total_bytes !== "" && Number.isFinite(totalBytes) && totalBytes >= 0;
    $("geodata-total-bytes").textContent = hasTotalBytes ? formatBytes(totalBytes) : "Нет данных";
    $("geodata-last-update").textContent = formatDate(model.geodata_last_update) || "Ещё не загружались";

    const warning = typeof model.geodata_warning === "string" ? model.geodata_warning.trim() : "";
    $("geodata-warning-text").textContent = warning;
    $("geodata-api-warning").classList.toggle("hidden", !warning);
  }

  function renderSettings(force = false) {
    const fingerprint = settingsStateSignature();
    if (!force && (ui.settingsDirty || fingerprint === settingsFingerprint)) return;
    settingsFingerprint = fingerprint;
    renderHeaders("global-header-rows", decode(model.global_headers_b64), true);
    all('input[name="listener-mode"]').forEach((input) => { input.checked = input.value === (model.listener_mode || "auto"); });
    $("redir-port").value = model.redir_port ?? 12345;
    $("tproxy-port").value = model.tproxy_port ?? 12346;
    $("network-qdisc").value = model.network_qdisc || "fq_codel";
    $("network-ipv6").checked = Number(model.network_disable_ipv6 ?? 1) === 0;
    $("network-multicast").checked = Number(model.network_disable_multicast ?? 1) === 0;
    $("xray-log-level").value = model.log_level || "warning";
    $("dns-override-enabled").checked = enabled(model.dns_override_enabled);
    $("dns-override").value = model.dns_override || "";
    updateDnsOverrideFields();
    $("inbound-strip-socks").checked = enabled(model.inbound_strip_socks ?? 1);
    $("inbound-strip-http").checked = enabled(model.inbound_strip_http ?? 1);
    $("local-socks-enabled").checked = enabled(model.local_socks_enabled);
    $("local-socks-port").value = model.local_socks_port ?? 1080;
    $("local-socks-user").value = model.local_socks_user || "";
    $("local-socks-pass").value = "";
    $("local-socks-pass").placeholder = model.local_socks_has_pass ? "сохранён" : "";
    $("local-socks-pass-clear").checked = false;
    $("local-http-enabled").checked = enabled(model.local_http_enabled);
    $("local-http-port").value = model.local_http_port ?? 1081;
    $("local-http-user").value = model.local_http_user || "";
    $("local-http-pass").value = "";
    $("local-http-pass").placeholder = model.local_http_has_pass ? "сохранён" : "";
    $("local-http-pass-clear").checked = false;
    updateLocalInboundFields();
    $("xray-log-error").value = model.xray_log_error || "/dev/stderr";
    $("xray-log-access").value = model.xray_log_access || "/dev/stdout";
    $("xray-log-dns").checked = enabled(model.xray_log_dns);
    $("xray-log-mask-address").checked = enabled(model.xray_log_mask_address);
    $("xray-sniffing-enabled").checked = Number(model.xray_sniffing_enabled ?? 1) !== 0;
    $("xray-sniffing-route-only").checked = Number(model.xray_sniffing_route_only ?? 0) !== 0;
    $("xray-probe-url").value = model.xray_probe_url || "https://www.gstatic.com/generate_204";
    $("xray-probe-timeout-seconds").value = model.xray_probe_timeout_seconds || 5;
    const probeMethod = String(model.xray_probe_http_method || "HEAD").toUpperCase();
    $("xray-probe-http-method").value = probeMethod === "GET" ? "GET" : "HEAD";
    const geodataStorage = model.geodata_storage === "persistent" ? "persistent" : "memory";
    all('input[name="geodata-storage"]').forEach((input) => { input.checked = input.value === geodataStorage; });
    const timeoutDefaults = {
      established: 86400, unacknowledged: 300, "syn-sent": 5, "syn-recv": 5,
      "fin-wait": 10, "close-wait": 10, "last-ack": 10, "time-wait": 10,
      close: 10, "udp-stream": 180,
    };
    Object.entries(timeoutDefaults).forEach(([name, fallback]) => {
      const key = `network_ct_${name.replaceAll("-", "_")}`;
      $(`network-ct-${name}`).value = model[key] || fallback;
    });
    ui.themeDraft = undefined;
    ui.accentDraft = undefined;
    ui.settingsDirty = false;
    applyCurrentTheme();
    renderThemeControls();
    updateListenerDescription();
    updateSniffingFields();
    updateGeodataFields();
  }

  function updateProfileHeaders() {
    const enabled = $("profile-use-headers").checked;
    document.querySelector(".profile-headers-body").classList.toggle("disabled", !enabled);
  }

  function renderProviderMetadata(profile) {
    if (!profile) {
      $("profile-provider-meta").classList.add("hidden");
      $("profile-editor-alert").classList.add("hidden");
      return;
    }
    const userInfoRaw = decode(profile.userinfo_b64);
    const userInfo = parseUserInfo(userInfoRaw);
    const title = decodeHeader(profile.title_b64);
    const announcement = decodeHeader(profile.announce_b64);
    const support = safeHttpUrl(decode(profile.support_url_b64));
    const page = safeHttpUrl(decode(profile.web_page_url_b64));
    const providerInterval = Number(profile.provider_refresh_seconds) || 0;
    const intervalHeader = decode(profile.interval_b64);
    const policyText = profilePolicyEntries(profile).join(" · ");
    const hasMetadata = Boolean(profile.fetched_at || title || userInfoRaw || announcement || support || page || providerInterval || intervalHeader || policyText);
    $("profile-provider-meta").classList.toggle("hidden", !hasMetadata);
    $("profile-provider-title").textContent = title || decode(profile.name_b64) || "Профиль";
    $("profile-provider-interval").textContent = providerInterval ? formatInterval(providerInterval) : intervalHeader || "Не задан";
    $("profile-provider-traffic").textContent = userInfo.used === null
      ? "Не задан"
      : userInfo.total ? `${formatBytes(userInfo.used)} из ${formatBytes(userInfo.total)}` : `Использовано ${formatBytes(userInfo.used)}`;
    $("profile-provider-expire").textContent = userInfo.expiry || "Не задано";
    $("profile-provider-announce").textContent = announcement;
    $("profile-provider-announce").classList.toggle("hidden", !announcement);
    $("profile-provider-hwid").textContent = policyText;
    $("profile-provider-hwid").classList.toggle("hidden", !policyText);
    const pageLink = $("profile-provider-page");
    const supportLink = $("profile-provider-support");
    pageLink.classList.toggle("hidden", !page);
    supportLink.classList.toggle("hidden", !support);
    pageLink.removeAttribute("href");
    supportLink.removeAttribute("href");
    if (page) pageLink.href = page;
    if (support) supportLink.href = support;
    $("profile-provider-links").classList.toggle("hidden", !page && !support);
    const showDiagnostic = Boolean(profileError(profile) || enabled(profile.using_previous_config) || enabled(profile.fail_closed) || profile.refresh_state === "error");
    $("profile-editor-alert").classList.toggle("hidden", !showDiagnostic);
    $("profile-editor-error").textContent = profileDiagnostic(profile);
  }

  function openEditor(profileId = "") {
    const profile = profileId ? profileById(profileId) : null;
    ui.editorProfileId = profileId;
    ui.editorDirty = false;
    $("profile-id").value = profileId;
    $("editor-title").textContent = profile ? profileName(profile) : "Новая подписка";
    $("profile-name").value = profile ? decode(profile.name_b64) : "Новая подписка";
    $("profile-url").value = profile ? profileUrl(profile) : "";
    $("profile-refresh").value = profile ? Math.max(1, Math.round(Number(profile.refresh_seconds) / 60)) : 60;
    $("profile-timeout").value = profile?.timeout_seconds || 30;
    $("profile-use-provider-title").checked = Number(profile?.use_provider_title ?? 1) !== 0;
    $("profile-use-provider-interval").checked = Number(profile?.use_provider_interval ?? 1) !== 0;
    $("profile-insecure").checked = Number(profile?.insecure_tls || 0) !== 0;
    $("profile-use-headers").checked = Number(profile?.use_profile_headers ?? 1) !== 0;
    renderHeaders("profile-header-rows", profile ? decode(profile.headers_b64) : "", false);
    updateProfileHeaders();
    renderProviderMetadata(profile);
    $("profile-request-details").open = Boolean(profile && (decode(profile.headers_b64) || Number(profile.use_profile_headers ?? 1) === 0));
    $("profile-modal-layer").classList.remove("hidden");
    setTimeout(() => $(profile ? "profile-name" : "profile-url").focus(), 0);
  }

  function closeEditor(force = false) {
    if (!force && ui.editorDirty && !confirm("Закрыть редактор и отбросить несохранённые изменения?")) return;
    $("profile-modal-layer").classList.add("hidden");
    ui.editorProfileId = "";
    ui.editorDirty = false;
  }

  async function readProfileJson(kind, profileId) {
    const response = await fetch(`/cgi-bin/api?action=${encodeURIComponent(kind)}&profile_id=${encodeURIComponent(profileId)}`);
    const text = await response.text();
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    try {
      const parsed = JSON.parse(text);
      return parsed === null ? "Файл ещё не создан." : JSON.stringify(parsed, null, 2);
    } catch {
      return text || "Файл ещё не создан.";
    }
  }

  // Подсветка JSON. Токенизируем исходный текст, а экранируем уже каждый
  // кусок отдельно: если сначала экранировать всё, кавычки станут &quot; и
  // строки перестанут находиться. Цвета задаются классами — инлайн-стиль
  // страница не пропустит, у неё CSP style-src 'self'.
  const JSON_TOKEN = /"(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g;
  const JSON_HIGHLIGHT_LIMIT = 400000;

  function highlightJson(text) {
    let out = "";
    let last = 0;
    for (const match of text.matchAll(JSON_TOKEN)) {
      const token = match[0];
      out += escapeHtml(text.slice(last, match.index));
      let className;
      if (token.startsWith('"')) className = /^\s*:/.test(text.slice(match.index + token.length)) ? "j-key" : "j-str";
      else if (token === "null") className = "j-null";
      else if (token === "true" || token === "false") className = "j-bool";
      else className = "j-num";
      out += `<span class="${className}">${escapeHtml(token)}</span>`;
      last = match.index + token.length;
    }
    return out + escapeHtml(text.slice(last));
  }

  function showJson(viewer, text) {
    // Очень большой ответ не подсвечиваем: разметка на каждый токен утяжеляет
    // DOM сильнее, чем стоит удобство, а роутер не самый быстрый.
    if (text.length > JSON_HIGHLIGHT_LIMIT) {
      viewer.textContent = text;
      return;
    }
    viewer.innerHTML = highlightJson(text);
  }

  async function openJsonModal(kind, profileId = model.active_profile_id) {
    const profile = profileById(profileId);
    if (!profile) return toast("Профиль не выбран", "error");
    const source = kind === "source";
    const layer = $(source ? "source-json-modal" : "runtime-json-modal");
    const viewer = $(source ? "source-json-viewer" : "runtime-json-viewer");
    const subtitle = $(source ? "source-json-subtitle" : "runtime-json-subtitle");
    subtitle.textContent = source ? `${profileName(profile)} · ответ источника без локальных изменений` : `${profileName(profile)} · выбранный JSON с локальными входами RouterOS`;
    viewer.textContent = "Загрузка...";
    layer.dataset.profileId = profileId;
    layer.classList.remove("hidden");
    try {
      showJson(viewer, await readProfileJson(kind, profileId));
    } catch (error) {
      viewer.textContent = `Ошибка загрузки: ${error.message}`;
    }
  }

  function closeModal(id) {
    $(id).classList.add("hidden");
  }

  async function copyText(value, successMessage) {
    try {
      await navigator.clipboard.writeText(value);
    } catch {
      const textarea = document.createElement("textarea");
      textarea.value = value;
      textarea.style.position = "fixed";
      textarea.style.opacity = "0";
      document.body.appendChild(textarea);
      textarea.select();
      document.execCommand("copy");
      textarea.remove();
    }
    toast(successMessage);
  }

  function renderActionStates() {
    if (!model || !model.profiles) return;
    $("save-settings").disabled = ui.busy.has("settings");
    $("save-profile").disabled = ui.busy.has("profile-save");
    $("rebuild-runtime").disabled = ui.busy.has("rebuild");
    $("generate-basic-auth-hash").disabled = ui.busy.has("hash");
    $("add-profile").disabled = ui.busy.has("select");
  }

  function render(forceSettings = false) {
    renderRuntime();
    renderSubscriptions();
    renderSettings(forceSettings);
    // Сводка geodata только читается и ни к какому полю формы не привязана,
    // поэтому обновляется всегда. Внутри renderSettings она попадала под флаг
    // settingsDirty: стоило тронуть любую настройку — и размер с временем
    // файлов замирали до сохранения или перезагрузки страницы.
    updateGeodataFields();
    renderActionStates();
    if (ui.editorProfileId) {
      const editorProfile = profileById(ui.editorProfileId);
      renderProviderMetadata(editorProfile);
    }
  }

  async function refresh(forceSettings = false) {
    if (refreshPending) return;
    refreshPending = true;
    try {
      const result = await api("status");
      result.profiles = Array.isArray(result.profiles) ? result.profiles : [];
      result.configs = Array.isArray(result.configs) ? result.configs : [];
      model = result;
      settlePendingSelection();
      pollFailures = 0;
      render(forceSettings);
    } catch (error) {
      pollFailures += 1;
      if (pollFailures <= 2) toast(error.message, "error");
    } finally {
      refreshPending = false;
    }
  }

  async function selectProfile(profileId) {
    if (!profileId || profileId === model.active_profile_id || ui.selectingProfileId) return;
    ui.selectingProfileId = profileId;
    cardsFingerprint = "";
    renderSubscriptions();
    try {
      await api("select", { profile_id: profileId });
      await refresh();
    } finally {
      ui.selectingProfileId = "";
      cardsFingerprint = "";
      renderSubscriptions();
    }
  }

  async function selectConfig(configIndex) {
    const profile = activeProfile();
    if (!profile || !Number.isInteger(Number(configIndex)) || ui.pendingConfig) return;
    const config = model.configs.find((entry) => Number(entry.index) === Number(configIndex));
    if (!config) return;
    const alreadySelected = profile.selected_config_fingerprint
      ? config.fingerprint === profile.selected_config_fingerprint
      : Number(config.index) === Number(profile.selected_config_index);
    if (alreadySelected) return;
    // Выбор запоминается до запроса и держится, пока контейнер не подтвердит
    // его в статусе. Раньше подсветка бралась только из модели, а её заменяет
    // каждый опрос — пока шла пересборка, сервер ещё отдавал прежнюю строку, и
    // выделение прыгало туда-сюда.
    ui.pendingConfig = { profileId: profile.id, index: Number(config.index), fingerprint: config.fingerprint, at: Date.now() };
    cardsFingerprint = "";
    renderSubscriptions();
    try {
      const result = await api("select-config", { profile_id: profile.id, config_index: String(Number(configIndex)) });
      if (!result.changed) {
        ui.pendingConfig = null;
        cardsFingerprint = "";
        renderSubscriptions();
        return;
      }
      toast("Конфигурация выбрана, обновление поставлено в очередь");
      await refresh();
    } catch (error) {
      ui.pendingConfig = null;
      cardsFingerprint = "";
      renderSubscriptions();
      throw error;
    }
  }

  function pendingSelectionFor(profile) {
    const pending = ui.pendingConfig;
    if (!pending || pending.profileId !== profile.id) return null;
    return pending;
  }

  // Ожидание снимается, когда контейнер отдал ту же строку выбранной, либо по
  // сроку: иначе неудача на стороне контейнера оставила бы список навсегда
  // заблокированным.
  function settlePendingSelection() {
    const pending = ui.pendingConfig;
    if (!pending) return;
    const profile = profileById(pending.profileId);
    const confirmed = profile && (profile.selected_config_fingerprint
      ? profile.selected_config_fingerprint === pending.fingerprint
      : Number(profile.selected_config_index) === pending.index);
    if (confirmed || !profile || Date.now() - pending.at > 90000) ui.pendingConfig = null;
  }

  async function probeConfig(configIndex, quiet = false) {
    const profile = activeProfile();
    const config = model.configs.find((entry) => Number(entry.index) === Number(configIndex));
    if (!profile || !config) return;
    const key = `${profile.id}:${config.fingerprint || config.index}`;
    if (ui.probes.get(key)?.pending) return;
    ui.probes.set(key, { pending: true });
    cardsFingerprint = "";
    renderSubscriptions();
    try {
      const result = await api("probe-config", { profile_id: profile.id, config_index: String(Number(config.index)) });
      ui.probes.set(key, {
        pending: false,
        delay_ms: result.delay_ms,
        alive: Number(result.alive),
        total: Number(result.total),
        method: result.method,
        source: result.source,
      });
    } catch (error) {
      ui.probes.set(key, { pending: false, error: error.message || String(error) });
      if (!quiet) toast(error.message || String(error), "error");
    } finally {
      cardsFingerprint = "";
      renderSubscriptions();
    }
  }

  async function probeAllConfigs() {
    const profile = activeProfile();
    if (!profile) return;
    const key = `probe-all:${profile.id}`;
    if (ui.busy.has(key)) return;
    ui.busy.add(key);
    cardsFingerprint = "";
    renderSubscriptions();
    const probeKeyOf = (config) => `${profile.id}:${config.fingerprint || config.index}`;
    const snapshot = [...model.configs];
    snapshot.forEach((config) => ui.probes.set(probeKeyOf(config), { pending: true }));
    cardsFingerprint = "";
    renderSubscriptions();
    try {
      // Один запрос вместо цикла по конфигурациям: контейнер поднимает одно
      // ядро и опрашивает все outbound разом.
      const result = await api("probe-all", { profile_id: profile.id });
      const byIndex = new Map(snapshot.map((config) => [Number(config.index), config]));
      (result.results || []).forEach((entry) => {
        const config = byIndex.get(Number(entry.index));
        if (!config) return;
        ui.probes.set(probeKeyOf(config), {
          pending: false,
          delay_ms: entry.delay_ms,
          method: entry.method,
          source: entry.source,
        });
      });
      snapshot.forEach((config) => {
        const probeKey = probeKeyOf(config);
        if (!ui.probes.get(probeKey)?.pending) return;
        ui.probes.set(probeKey, { pending: false, error: "В конфигурации нет proxy-outbound для проверки" });
      });
      toast("HTTP-проверка завершена");
    } catch (error) {
      snapshot.forEach((config) => {
        const probeKey = probeKeyOf(config);
        if (!ui.probes.get(probeKey)?.pending) return;
        ui.probes.set(probeKey, { pending: false, error: error.message || String(error) });
      });
      toast(error.message || String(error), "error");
    } finally {
      ui.busy.delete(key);
      cardsFingerprint = "";
      renderSubscriptions();
    }
  }

  async function toggleRuntime() {
    const profile = activeProfile();
    if (!profile) throw new Error("Сначала выберите подписку");
    const stopping = Boolean(model.run_enabled);
    await api(stopping ? "stop" : "start", {});
    toast(stopping ? "Xray останавливается" : "Xray запускается");
    await refresh();
  }

  async function refreshProfile(profileId) {
    await api("refresh", { profile_id: profileId });
    toast("Обновление поставлено в очередь");
    await refresh();
  }

  async function saveProfile(event) {
    event.preventDefault();
    if (!$("profile-form").reportValidity()) return;
    const originalId = ui.editorProfileId;
    let profileId = originalId;
    let created = false;
    setBusy("profile-save", true);
    try {
      if (!profileId) {
        const result = await api("create", { name: $("profile-name").value.trim() || "Новая подписка" });
        profileId = result.id;
        created = true;
      }
      await api("save-profile", {
        profile_id: profileId,
        name: $("profile-name").value.trim(),
        url: $("profile-url").value.trim(),
        headers: collectHeaders("profile-header-rows"),
        refresh_seconds: String(Math.round(Number($("profile-refresh").value) * 60)),
        timeout_seconds: $("profile-timeout").value,
        insecure_tls: $("profile-insecure").checked ? "1" : "0",
        use_profile_headers: $("profile-use-headers").checked ? "1" : "0",
        use_provider_title: $("profile-use-provider-title").checked ? "1" : "0",
        use_provider_interval: $("profile-use-provider-interval").checked ? "1" : "0",
      });
      if (profileId !== model.active_profile_id) await api("select", { profile_id: profileId });
      ui.editorDirty = false;
      closeEditor(true);
      toast(created ? "Подписка добавлена" : "Профиль сохранён");
      await refresh();
    } catch (error) {
      if (created && profileId) {
        try { await api("delete", { profile_id: profileId }); } catch {}
      }
      toast(error.message, "error");
    } finally {
      setBusy("profile-save", false);
    }
  }

  async function saveSettings(event) {
    event.preventDefault();
    if (!$("settings-form").reportValidity()) return;
    await perform("settings", async () => {
      const listenerMode = document.querySelector('input[name="listener-mode"]:checked')?.value || "auto";
      await api("save-settings", {
        global_headers_present: "1",
        global_headers: collectHeaders("global-header-rows"),
        listener_mode: listenerMode,
        redir_port: $("redir-port").value,
        tproxy_port: $("tproxy-port").value,
        log_level: $("xray-log-level").value,
        dns_override_enabled: $("dns-override-enabled").checked ? "1" : "0",
        dns_override_present: "1",
        dns_override: $("dns-override").value,
        inbound_strip_socks: $("inbound-strip-socks").checked ? "1" : "0",
        inbound_strip_http: $("inbound-strip-http").checked ? "1" : "0",
        local_socks_enabled: $("local-socks-enabled").checked ? "1" : "0",
        local_socks_port: $("local-socks-port").value,
        local_socks_user: $("local-socks-user").value.trim(),
        local_socks_pass: $("local-socks-pass").value,
        local_socks_pass_clear: $("local-socks-pass-clear").checked ? "1" : "0",
        local_http_enabled: $("local-http-enabled").checked ? "1" : "0",
        local_http_port: $("local-http-port").value,
        local_http_user: $("local-http-user").value.trim(),
        local_http_pass: $("local-http-pass").value,
        local_http_pass_clear: $("local-http-pass-clear").checked ? "1" : "0",
        xray_log_error: $("xray-log-error").value.trim(),
        xray_log_access: $("xray-log-access").value.trim(),
        xray_log_dns: $("xray-log-dns").checked ? "1" : "0",
        xray_log_mask_address: $("xray-log-mask-address").checked ? "1" : "0",
        network_qdisc: $("network-qdisc").value,
        network_disable_ipv6: $("network-ipv6").checked ? "0" : "1",
        network_disable_multicast: $("network-multicast").checked ? "0" : "1",
        network_ct_established: $("network-ct-established").value,
        network_ct_unacknowledged: $("network-ct-unacknowledged").value,
        network_ct_syn_sent: $("network-ct-syn-sent").value,
        network_ct_syn_recv: $("network-ct-syn-recv").value,
        network_ct_fin_wait: $("network-ct-fin-wait").value,
        network_ct_close_wait: $("network-ct-close-wait").value,
        network_ct_last_ack: $("network-ct-last-ack").value,
        network_ct_time_wait: $("network-ct-time-wait").value,
        network_ct_close: $("network-ct-close").value,
        network_ct_udp_stream: $("network-ct-udp-stream").value,
        xray_sniffing_enabled: $("xray-sniffing-enabled").checked ? "1" : "0",
        xray_sniffing_route_only: $("xray-sniffing-route-only").checked ? "1" : "0",
        xray_probe_url: $("xray-probe-url").value.trim(),
        xray_probe_timeout_seconds: $("xray-probe-timeout-seconds").value,
        xray_probe_http_method: $("xray-probe-http-method").value,
        geodata_storage: document.querySelector('input[name="geodata-storage"]:checked')?.value || "memory",
        ui_theme: currentTheme(),
        ui_accent_present: "1",
        ui_accent: currentAccent(),
      });
      ui.settingsDirty = false;
      settingsFingerprint = "";
      toast("Настройки сохранены");
      await refresh(true);
    });
  }

  function requestDelete(profileId) {
    const profile = profileById(profileId);
    if (!profile || profileId === model.active_profile_id) return;
    ui.deleteProfileId = profileId;
    $("delete-message").textContent = `Профиль «${profileName(profile)}», исходный JSON и рабочая конфигурация будут удалены.`;
    $("delete-modal").classList.remove("hidden");
  }

  async function confirmDelete() {
    const profileId = ui.deleteProfileId;
    if (!profileId) return;
    await perform("delete", async () => {
      await api("delete", { profile_id: profileId });
      closeModal("delete-modal");
      ui.deleteProfileId = "";
      toast("Подписка удалена");
      await refresh();
    });
  }

  all("[data-page-link]").forEach((button) => button.addEventListener("click", () => showPage(button.dataset.pageLink)));
  all("[data-settings-tab]").forEach((button) => button.addEventListener("click", () => showSettingsTab(button.dataset.settingsTab)));

  $("add-profile").addEventListener("click", () => openEditor());
  $("empty-add-profile").addEventListener("click", () => openEditor());
  $("close-editor").addEventListener("click", () => closeEditor());
  $("cancel-editor").addEventListener("click", () => closeEditor());
  $("profile-form").addEventListener("submit", saveProfile);
  $("profile-form").addEventListener("input", () => { ui.editorDirty = true; });
  $("profile-use-headers").addEventListener("change", updateProfileHeaders);
  $("add-profile-header").addEventListener("click", () => {
    appendHeader("profile-header-rows");
    ui.editorDirty = true;
  });
  $("profile-header-rows").addEventListener("click", (event) => {
    const button = event.target.closest("[data-remove-header]");
    if (!button) return;
    button.closest(".header-row").remove();
    ui.editorDirty = true;
  });

  $("subscription-list").addEventListener("click", (event) => {
    const probeAllButton = event.target.closest("[data-probe-all]");
    if (probeAllButton) {
      event.stopPropagation();
      if (!probeAllButton.disabled) probeAllConfigs();
      return;
    }
    const probeButton = event.target.closest("[data-probe-index]");
    if (probeButton) {
      event.stopPropagation();
      if (!probeButton.disabled) probeConfig(probeButton.dataset.probeIndex);
      return;
    }
    const configButton = event.target.closest("[data-config-index]");
    if (configButton) {
      event.stopPropagation();
      if (configButton.disabled) return;
      perform("config", () => selectConfig(configButton.dataset.configIndex));
      return;
    }
    const actionButton = event.target.closest("[data-profile-action]");
    if (actionButton) {
      event.stopPropagation();
      if (actionButton.disabled) return;
      const id = actionButton.dataset.profileId;
      const action = actionButton.dataset.profileAction;
      if (action === "edit") {
        perform("select", async () => {
          if (id !== model.active_profile_id) await selectProfile(id);
          openEditor(id);
        });
      } else if (action === "refresh") {
        perform("refresh", () => refreshProfile(id));
      } else if (action === "source") {
        openJsonModal("source", id);
      } else if (action === "delete") {
        requestDelete(id);
      } else if (action === "start" || action === "stop") {
        perform("runtime", toggleRuntime);
      }
      return;
    }
    const selectButton = event.target.closest("[data-profile-select]");
    if (selectButton && !selectButton.disabled) perform("select", () => selectProfile(selectButton.dataset.profileSelect));
  });

  $("open-active-runtime").addEventListener("click", () => openJsonModal("config"));
  $("open-runtime-events").addEventListener("click", () => $("runtime-events-modal").classList.remove("hidden"));

  $("close-source-json").addEventListener("click", () => closeModal("source-json-modal"));
  $("done-source-json").addEventListener("click", () => closeModal("source-json-modal"));
  $("close-runtime-json").addEventListener("click", () => closeModal("runtime-json-modal"));
  $("done-runtime-json").addEventListener("click", () => closeModal("runtime-json-modal"));
  $("close-runtime-events").addEventListener("click", () => closeModal("runtime-events-modal"));
  $("done-runtime-events").addEventListener("click", () => closeModal("runtime-events-modal"));
  $("delete-cancel").addEventListener("click", () => closeModal("delete-modal"));
  $("delete-confirm").addEventListener("click", confirmDelete);

  $("copy-source-json").addEventListener("click", () => copyText($("source-json-viewer").textContent, "Исходный JSON скопирован"));
  $("copy-runtime-json").addEventListener("click", () => copyText($("runtime-json-viewer").textContent, "Рабочий JSON скопирован"));
  $("copy-runtime-events").addEventListener("click", () => copyText($("runtime-events").value, "События скопированы"));

  $("rebuild-runtime").addEventListener("click", () => perform("rebuild", async () => {
    const profileId = $("runtime-json-modal").dataset.profileId || model.active_profile_id;
    await api("rebuild", { profile_id: profileId });
    toast("Пересборка поставлена в очередь");
    await refresh();
  }));

  $("theme-grid").addEventListener("click", (event) => {
    const card = event.target.closest("[data-theme-id]");
    if (card) setTheme(card.dataset.themeId);
  });
  $("accent-presets").addEventListener("click", (event) => {
    const swatch = event.target.closest("[data-accent]");
    if (!swatch) return;
    setAccent(swatch.getAttribute("aria-pressed") === "true" ? "" : swatch.dataset.accent);
  });
  $("accent-color").addEventListener("input", (event) => setAccent(event.target.value));
  $("accent-reset").addEventListener("click", () => setAccent(""));
  theme.watchSystemTheme(currentTheme, currentAccent);

  $("settings-form").addEventListener("submit", saveSettings);
  $("settings-form").addEventListener("input", (event) => {
    if (event.target.closest('[data-settings-panel="access"]')) return;
    ui.settingsDirty = true;
  });
  all('input[name="listener-mode"]').forEach((input) => input.addEventListener("change", updateListenerDescription));
  all('input[name="geodata-storage"]').forEach((input) => input.addEventListener("change", updateGeodataFields));
  $("xray-sniffing-enabled").addEventListener("change", updateSniffingFields);
  $("dns-override-enabled").addEventListener("change", updateDnsOverrideFields);
  $("local-socks-enabled").addEventListener("change", updateLocalInboundFields);
  $("local-http-enabled").addEventListener("change", updateLocalInboundFields);
  // Переключатель перерисовывает список из того, что сейчас в редакторе, а не
  // из модели: иначе несохранённые правки пропали бы. Выключение убирает
  // обязательные строки, поэтому после сохранения они исчезают и из состояния,
  // и подставлять их будет уже нечему.
  $("add-global-header").addEventListener("click", () => {
    appendHeader("global-header-rows");
    ui.settingsDirty = true;
  });
  $("global-header-rows").addEventListener("click", (event) => {
    const button = event.target.closest("[data-remove-header]");
    if (!button) return;
    button.closest(".header-row").remove();
    ui.settingsDirty = true;
  });

  all("[data-toggle-password]").forEach((button) => button.addEventListener("click", () => {
    const input = $(button.dataset.togglePassword);
    input.type = input.type === "password" ? "text" : "password";
    button.title = input.type === "password" ? "Показать пароль" : "Скрыть пароль";
  }));

  $("generate-basic-auth-hash").addEventListener("click", () => perform("hash", async () => {
    const password = $("basic-auth-password").value;
    const confirmation = $("basic-auth-password-confirm").value;
    if (password.length < 8 || password.length > 128) throw new Error("Пароль должен содержать от 8 до 128 символов");
    if (password !== confirmation) throw new Error("Пароли не совпадают");
    const result = await api("hash", { password });
    $("basic-auth-hash").value = result.hash;
    $("basic-auth-hash-algorithm").textContent = result.algorithm === "sha512crypt"
      ? "sha512crypt · значение для переменной окружения контейнера"
      : "md5crypt · sha512 недоступен в этой сборке busybox";
    $("basic-auth-hash-result").classList.remove("hidden");
    $("basic-auth-password").value = "";
    $("basic-auth-password-confirm").value = "";
    toast("Хеш создан");
  }));
  $("copy-basic-auth-hash").addEventListener("click", () => copyText($("basic-auth-hash").value, "Хеш скопирован"));


  all(".modal-layer").forEach((layer) => layer.addEventListener("mousedown", (event) => {
    if (event.target !== layer) return;
    if (layer.id === "profile-modal-layer") closeEditor();
    else closeModal(layer.id);
  }));

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    const openLayers = all(".modal-layer:not(.hidden)");
    const layer = openLayers.at(-1);
    if (!layer) return;
    if (layer.id === "profile-modal-layer") closeEditor();
    else closeModal(layer.id);
  });

  window.addEventListener("beforeunload", (event) => {
    if (!ui.editorDirty && !ui.settingsDirty) return;
    event.preventDefault();
    event.returnValue = "";
  });

  // Каждый опрос статуса — это CGI-процесс на роутере, поэтому опрашивать
  // невидимую вкладку смысла нет: она всё равно ничего не показывает, а
  // забытая в фоне панель круглосуточно нагружала бы контейнер. При
  // недоступном API интервал растёт, иначе тост об ошибке появлялся бы каждые
  // три секунды до конца времён.
  function pollDelay() {
    if (pollFailures > 0) return Math.min(30000, 3000 * 2 ** (pollFailures - 1));
    return model.profiles.some((profile) => profile.refresh_state === "queued" || profile.refresh_state === "working") ? 800 : 3000;
  }

  function schedulePoll(delay = pollDelay()) {
    clearTimeout(pollTimer);
    if (document.hidden) return;
    pollTimer = setTimeout(poll, delay);
  }

  async function poll() {
    await refresh();
    schedulePoll();
  }

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) clearTimeout(pollTimer);
    else poll();
  });

  // Подписи «5 мин. назад» считаются на отрисовке, а отрисовка списка
  // пропускается, пока данные не изменились. Без этого тика относительное
  // время застывало бы на «только что» до следующего обновления подписки.
  setInterval(() => {
    if (document.hidden || ui.page !== "subscriptions") return;
    cardsFingerprint = "";
    renderSubscriptions();
  }, 30000);

  refresh(true).finally(() => schedulePoll(800));
})();

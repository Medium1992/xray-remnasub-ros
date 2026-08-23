// Тема и акцентный цвет панели.
//
// Источник истины — state.conf на стороне контейнера: панель открывают с
// разных устройств, и вид не должен зависеть от того, из какого браузера
// зашли. localStorage здесь только зеркало для самой первой отрисовки, чтобы
// страница не успела мигнуть чужой темой, пока не приехал ответ CGI.
// Расхождение всегда разрешается в пользу серверного значения.
//
// Скрипт подключается в <head> синхронно и до app.js именно ради этого:
// применить тему нужно раньше, чем браузер нарисует первый кадр.
(() => {
  "use strict";

  const THEMES = [
    { id: "auto", label: "Как в системе" },
    { id: "dark", label: "Тёмная" },
    { id: "light", label: "Светлая" },
    { id: "graphite", label: "Графит" },
    { id: "midnight", label: "Полночь" },
    { id: "forest", label: "Тайга" },
    { id: "sepia", label: "Сепия" },
  ];

  const ACCENT_PRESETS = ["#9bd45a", "#5cab7c", "#6c8de8", "#8a94a0", "#9a6a3a", "#c25a52"];

  const MIRROR_THEME = "xray-remnasub.theme";
  const MIRROR_ACCENT = "xray-remnasub.accent";

  const isTheme = (value) => THEMES.some((theme) => theme.id === value);

  // Акцент хранится обычным #rrggbb: это и то, что отдаёт <input type="color">,
  // и то, что валидирует CGI.
  const isAccent = (value) => /^#[0-9a-fA-F]{6}$/.test(String(value || ""));

  const hexToRgb = (hex) => [1, 3, 5].map((offset) => parseInt(hex.slice(offset, offset + 2), 16));

  const lighten = (hex, amount) =>
    `rgb(${hexToRgb(hex).map((value) => Math.round(value + (255 - value) * amount)).join(", ")})`;

  // Читаемый текст на кнопке акцентного цвета: по относительной яркости
  // выбирается тёмный или светлый, иначе на светлом акценте белые подписи
  // пропадают.
  const contrastContent = (hex) => {
    const [red, green, blue] = hexToRgb(hex).map((channel) => {
      const value = channel / 255;
      return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.36 ? "#141a10" : "#ffffff";
  };

  // "auto" в CSS не существует, поэтому раскрываем его здесь.
  const resolveTheme = (theme) => {
    if (theme !== "auto") return isTheme(theme) ? theme : "dark";
    return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  };

  function applyTheme(theme, accent) {
    const root = document.documentElement;
    root.dataset.theme = resolveTheme(theme);
    if (isAccent(accent)) {
      root.style.setProperty("--primary-rgb", hexToRgb(accent).join(", "));
      root.style.setProperty("--primary-hover", lighten(accent, 0.18));
      root.style.setProperty("--primary-content", contrastContent(accent));
    } else {
      root.style.removeProperty("--primary-rgb");
      root.style.removeProperty("--primary-hover");
      root.style.removeProperty("--primary-content");
    }
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", getComputedStyle(root).getPropertyValue("--base-200").trim());
    try {
      localStorage.setItem(MIRROR_THEME, theme);
      localStorage.setItem(MIRROR_ACCENT, isAccent(accent) ? accent : "");
    } catch {
      // Приватный режим или запрещённые данные сайта: зеркало необязательно.
    }
  }

  function applyMirroredTheme() {
    try {
      applyTheme(localStorage.getItem(MIRROR_THEME) || "auto", localStorage.getItem(MIRROR_ACCENT) || "");
    } catch {
      applyTheme("auto", "");
    }
  }

  // Пока выбрано «как в системе», переключение системной темы должно
  // подхватываться без перезагрузки страницы.
  function watchSystemTheme(getTheme, getAccent) {
    window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => {
      if (getTheme() === "auto") applyTheme("auto", getAccent());
    });
  }

  window.RemnaTheme = { THEMES, ACCENT_PRESETS, isTheme, isAccent, resolveTheme, applyTheme, watchSystemTheme };
  applyMirroredTheme();
})();

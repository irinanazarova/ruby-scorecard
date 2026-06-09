import { define } from "nanotags";

const KEY = "rsc-theme";

/**
 * <theme-toggle> — flips data-theme on <html> between light/dark.
 * The initial theme is applied by an inline script in <head> (no flash);
 * this component just owns the button and persistence.
 */
define("theme-toggle")
  .withRefs((r) => ({ button: r.one() }))
  .setup((ctx) => {
    const root = document.documentElement;

    const current = () =>
      root.dataset.theme ||
      (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");

    const paint = () => {
      const dark = current() === "dark";
      ctx.refs.button.setAttribute("aria-pressed", String(dark));
      const labelEl = ctx.refs.button.querySelector(".theme-toggle__label");
      if (labelEl) labelEl.textContent = dark ? "Dark" : "Light";
    };

    ctx.on(ctx.refs.button, "click", () => {
      const next = current() === "dark" ? "light" : "dark";
      root.dataset.theme = next;
      try {
        localStorage.setItem(KEY, next);
      } catch {}
      paint();
    });

    paint();
  });

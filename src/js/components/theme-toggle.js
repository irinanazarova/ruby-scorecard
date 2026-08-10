import { define } from "nanotags";

const KEY = "rsc-theme";

// Three states, and Auto is the default rather than a thing you can only reach by clearing storage.
//
// It used to be a two-state switch, which meant a first visit guessed a theme and then STUCK to it:
// press once to see the other one and the site stopped following your device forever, including
// when your device switched over at sunset. Auto is the absence of a stored preference, so the
// media query in tokens.css decides.
const ORDER = ["auto", "light", "dark"];
const LABEL = { auto: "Auto", light: "Light", dark: "Dark" };
const HINT = {
  auto: "Colour theme: following your device. Click for light.",
  light: "Colour theme: light. Click for dark.",
  dark: "Colour theme: dark. Click to follow your device."
};

/**
 * <theme-toggle> — cycles auto → light → dark on <html>.
 *
 * `data-theme` is set for light and dark and REMOVED for auto, because
 * `:root:not([data-theme])` is what lets the device preference through. The initial state is
 * applied by an inline script in <head> so there is no flash; this component owns the button,
 * the cycle and persistence.
 */
define("theme-toggle")
  .withRefs((r) => ({ button: r.one() }))
  .setup((ctx) => {
    const root = document.documentElement;

    // The stored choice, not the resolved colour: "auto" is a real answer here, and asking the
    // media query at this point would collapse it into whatever the device happens to be.
    const stored = () => {
      try {
        const saved = localStorage.getItem(KEY);
        return ORDER.includes(saved) ? saved : "auto";
      } catch {
        return root.dataset.theme || "auto";
      }
    };

    const paint = () => {
      const state = stored();
      const button = ctx.refs.button;
      const labelEl = button.querySelector(".theme-toggle__label");
      if (labelEl) labelEl.textContent = LABEL[state];
      button.setAttribute("aria-label", HINT[state]);
      button.setAttribute("title", HINT[state]);
      // Not aria-pressed: this is a three-state cycle, and a pressed/unpressed toggle would
      // announce two of the three states as the same thing.
      button.removeAttribute("aria-pressed");
      button.dataset.state = state;
    };

    ctx.on(ctx.refs.button, "click", () => {
      const next = ORDER[(ORDER.indexOf(stored()) + 1) % ORDER.length];

      if (next === "auto") {
        delete root.dataset.theme;
      } else {
        root.dataset.theme = next;
      }

      try {
        if (next === "auto") localStorage.removeItem(KEY);
        else localStorage.setItem(KEY, next);
      } catch {}

      paint();
    });

    paint();
  });

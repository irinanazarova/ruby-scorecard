import { define } from "nanotags";

/**
 * <stat-counter value="21" total="54"> — animates the numerator from 0 → value
 * on first view. The final text is server-rendered inside, so with JS off (or
 * reduced motion) the correct number is already there.
 */
define("stat-counter")
  .withProps((p) => ({ value: p.number(0), total: p.number(0) }))
  .withRefs((r) => ({ num: r.one() }))
  .setup((ctx) => {
    const { value, total } = {
      value: ctx.props.$value.get(),
      total: ctx.props.$total.get(),
    };
    const el = ctx.refs.num;
    const finalText = total ? `${value}/${total}` : String(value);

    if (matchMedia("(prefers-reduced-motion: reduce)").matches) {
      el.textContent = finalText;
      return;
    }

    let started = false;
    const run = () => {
      if (started) return;
      started = true;
      const dur = 900;
      let t0 = null;
      const step = (t) => {
        if (t0 === null) t0 = t;
        const k = Math.min(1, (t - t0) / dur);
        const eased = 1 - Math.pow(1 - k, 3);
        const n = Math.round(eased * value);
        el.textContent = total ? `${n}/${total}` : String(n);
        if (k < 1) requestAnimationFrame(step);
        else el.textContent = finalText;
      };
      requestAnimationFrame(step);
    };

    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          run();
          io.disconnect();
        }
      },
      { threshold: 0.4 }
    );
    io.observe(ctx.host);
    ctx.onCleanup(() => io.disconnect());
  });

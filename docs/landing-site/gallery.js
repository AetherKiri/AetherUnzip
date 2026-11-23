const gallery = document.querySelector(".preview");
const slides = [...gallery.querySelectorAll(".phone-screen img")];
const caption = gallery.querySelector("figcaption");
const controls = gallery.querySelector(".preview-controls");
const dots = [...controls.querySelectorAll(".preview-dot")];
const playback = controls.querySelector(".preview-playback");
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

let current = 0;
let timer;
let hovering = false;
let playing = !reducedMotion.matches;

function showSlide(index) {
  slides[current].hidden = true;
  dots[current].removeAttribute("aria-current");
  current = index;
  slides[current].hidden = false;
  dots[current].setAttribute("aria-current", "true");
  caption.textContent = slides[current].dataset.caption;
}

function schedule() {
  window.clearTimeout(timer);
  if (playing && !hovering && !document.hidden) {
    timer = window.setTimeout(() => {
      showSlide((current + 1) % slides.length);
      schedule();
    }, 5500);
  }
}

function setPlaying(value) {
  playing = value;
  playback.toggleAttribute("data-paused", !playing);
  playback.setAttribute("aria-label", playing ? "暂停轮播" : "播放轮播");
  schedule();
}

dots.forEach((dot, index) => dot.addEventListener("click", () => {
  setPlaying(false);
  if (index !== current) showSlide(index);
}));

playback.addEventListener("click", () => setPlaying(!playing));
gallery.addEventListener("focusin", (event) => {
  if (event.target !== playback && !gallery.contains(event.relatedTarget)) setPlaying(false);
});
gallery.addEventListener("pointerenter", (event) => {
  if (event.pointerType === "mouse") {
    hovering = true;
    schedule();
  }
});
gallery.addEventListener("pointerleave", () => {
  hovering = false;
  schedule();
});
document.addEventListener("visibilitychange", schedule);
reducedMotion.addEventListener("change", (event) => {
  if (event.matches) setPlaying(false);
});

controls.hidden = false;
setPlaying(playing);

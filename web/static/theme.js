// Light/dark toggle. The no-flash read of the stored preference happens inline
// in each page's <head>; this only wires the button.
(function () {
  var KEY = "escapement-theme";
  var button = document.getElementById("theme-toggle");
  if (!button) return;

  button.addEventListener("click", function () {
    var root = document.documentElement;
    var current = root.dataset.theme;
    if (!current) {
      current = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
    }
    var next = current === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    try {
      localStorage.setItem(KEY, next);
    } catch (e) {}
  });
})();

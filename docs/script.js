const navToggle = document.querySelector(".nav-toggle");
const siteNav = navToggle
  ? document.getElementById(navToggle.getAttribute("aria-controls") || "")
  : document.querySelector(".site-nav");

if (navToggle && siteNav) {
  navToggle.addEventListener("click", () => {
    const isOpen = siteNav.classList.toggle("is-open");
    navToggle.setAttribute("aria-expanded", String(isOpen));
    navToggle.setAttribute("aria-label", isOpen ? "Close menu" : "Open menu");
  });

  siteNav.querySelectorAll("a").forEach((link) => {
    link.addEventListener("click", () => {
      siteNav.classList.remove("is-open");
      navToggle.setAttribute("aria-expanded", "false");
      navToggle.setAttribute("aria-label", "Open menu");
    });
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    siteNav.classList.remove("is-open");
    navToggle.setAttribute("aria-expanded", "false");
    navToggle.setAttribute("aria-label", "Open menu");
  });
}

document.querySelectorAll("[data-year]").forEach((node) => {
  node.textContent = String(new Date().getFullYear());
});

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const revealNodes = document.querySelectorAll(".reveal");

if (!reducedMotion && "IntersectionObserver" in window) {
  const revealObserver = new IntersectionObserver(
    (entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    },
    { threshold: 0.14, rootMargin: "0px 0px -36px 0px" },
  );

  revealNodes.forEach((node) => revealObserver.observe(node));
} else {
  revealNodes.forEach((node) => node.classList.add("is-visible"));
}

const sections = [...document.querySelectorAll("main section[id]")];
const sectionLinks = [...document.querySelectorAll('.site-nav a[href^="#"]')];

if (sections.length && sectionLinks.length && "IntersectionObserver" in window) {
  const activeMap = new Map(
    sectionLinks.map((link) => [link.getAttribute("href")?.slice(1), link]),
  );
  const sectionObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        const link = activeMap.get(entry.target.id);
        if (!link || !entry.isIntersecting) return;
        sectionLinks.forEach((item) => item.classList.remove("is-active"));
        link.classList.add("is-active");
      });
    },
    { threshold: 0.4, rootMargin: "-15% 0px -45% 0px" },
  );
  sections.forEach((section) => sectionObserver.observe(section));
}

const desktopFrame = document.querySelector(".desktop-frame");
if (desktopFrame && !reducedMotion && window.matchMedia("(pointer: fine)").matches) {
  desktopFrame.addEventListener("pointermove", (event) => {
    const rect = desktopFrame.getBoundingClientRect();
    const x = (event.clientX - rect.left) / rect.width - 0.5;
    const y = (event.clientY - rect.top) / rect.height - 0.5;
    desktopFrame.style.setProperty("--tilt-x", `${(-y * 3).toFixed(2)}deg`);
    desktopFrame.style.setProperty("--tilt-y", `${(x * 4).toFixed(2)}deg`);
    desktopFrame.style.setProperty("--float-x", `${(x * 3).toFixed(2)}px`);
    desktopFrame.style.setProperty("--float-y", `${(y * 3).toFixed(2)}px`);
  });

  desktopFrame.addEventListener("pointerleave", () => {
    desktopFrame.style.removeProperty("--tilt-x");
    desktopFrame.style.removeProperty("--tilt-y");
    desktopFrame.style.removeProperty("--float-x");
    desktopFrame.style.removeProperty("--float-y");
  });
}

const repository = document.body.dataset.repository;
const releaseStatus = document.querySelector("[data-release-status]");

if (repository) {
  const fallbackReleaseUrl = `https://github.com/${repository}/releases/latest`;

  fetch(`https://api.github.com/repos/${repository}/releases/latest`, {
    headers: { Accept: "application/vnd.github+json" },
  })
    .then((response) => {
      if (!response.ok) throw new Error(`GitHub API returned ${response.status}`);
      return response.json();
    })
    .then((release) => {
      const assets = new Map(
        (release.assets || []).map((asset) => [asset.name, asset.browser_download_url]),
      );

      document.querySelectorAll("[data-release-link]").forEach((link) => {
        link.href = release.html_url || fallbackReleaseUrl;
      });
      document.querySelectorAll("[data-version]").forEach((node) => {
        node.textContent = release.tag_name || "latest";
      });
      document.querySelectorAll("[data-asset], [data-asset-pattern]").forEach((link) => {
        const card = link.closest(".download-card");
        const pattern = link.dataset.assetPattern
          ? new RegExp(link.dataset.assetPattern)
          : null;
        const assetUrl = pattern
          ? [...assets].find(([name]) => pattern.test(name))?.[1]
          : assets.get(link.dataset.asset);
        link.href = assetUrl || release.html_url || fallbackReleaseUrl;
        if (assetUrl) {
          card?.classList.add("is-ready");
        } else {
          card?.classList.add("is-missing");
          link.textContent = "Open release";
        }
      });

      if (releaseStatus) {
        const date = release.published_at
          ? new Intl.DateTimeFormat("en", { dateStyle: "medium" }).format(new Date(release.published_at))
          : null;
        releaseStatus.textContent = date
          ? `${release.name || release.tag_name} · published ${date}`
          : release.name || release.tag_name || "Latest release";
        releaseStatus.classList.add("is-loaded");
      }
    })
    .catch(() => {
      document.querySelectorAll("[data-release-link], [data-asset], [data-asset-pattern]").forEach((link) => {
        link.href = fallbackReleaseUrl;
      });
      if (releaseStatus) {
        releaseStatus.textContent = "Latest release is available on GitHub";
        releaseStatus.classList.add("is-error");
      }
    });
}

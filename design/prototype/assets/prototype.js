const iconPaths = {
  studio: '<circle cx="12" cy="12" r="6.5"/><circle cx="12" cy="12" r="2"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2"/>',
  projects: '<path d="M3.5 7.5h6l1.5 2h9.5v9.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/><path d="M3.5 8V5a2 2 0 0 1 2-2h4l1.5 2h5"/>',
  recovery: '<path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3L4.5 9"/><path d="M4.5 4.5V9H9"/><path d="M12 8v4l2.5 2"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1a1.7 1.7 0 0 0 1.9.3A1.7 1.7 0 0 0 10 3v-.2h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1z"/>',
  display: '<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8M12 17v4"/>',
  mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3M9 21h6"/>',
  audio: '<path d="M4 13h3l4 4V7L7 11H4z"/><path d="M15 9a4 4 0 0 1 0 6M18 6a8 8 0 0 1 0 12"/>',
  camera: '<rect x="3" y="5" width="14" height="14" rx="2"/><path d="m17 10 4-2v8l-4-2z"/>',
  layout: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M14 4v16M14 13h7"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m16 16 4.5 4.5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  chevron: '<path d="m9 6 6 6-6 6"/>',
  more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  folder: '<path d="M3.5 7.5h6l1.5 2h9.5v9a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/><path d="M3.5 8V5.5a2 2 0 0 1 2-2h4l1.5 2h5"/>',
  shield: '<path d="M12 3 4.5 6v5c0 4.8 3 8.1 7.5 10 4.5-1.9 7.5-5.2 7.5-10V6z"/><path d="m8.5 12 2.3 2.3 4.7-5"/>',
  warning: '<path d="M12 3 2.8 20h18.4z"/><path d="M12 9v5M12 17.5v.1"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  export: '<path d="M12 3v12M7 8l5-5 5 5"/><path d="M5 13v7h14v-7"/>',
  play: '<path d="m9 6 9 6-9 6z"/>',
  scissors: '<circle cx="6" cy="7" r="3"/><circle cx="6" cy="17" r="3"/><path d="m8.5 8.5 11 7M8.5 15.5l11-7"/>',
  transcript: '<path d="M5 5h14M7 9h10M5 13h14M8 17h8M10 21h4"/>',
  disk: '<path d="M4 4h13l3 3v13H4z"/><path d="M8 4v6h8V4M8 20v-6h8v6"/>',
  cursor: '<path d="m5 3 6.6 16 2.1-6.1 6.3-2z"/>',
  keyboard: '<rect x="3" y="6" width="18" height="12" rx="2"/><path d="M7 10h.1M11 10h.1M15 10h.1M18 10h.1M7 14h.1M11 14h6"/>',
  waveform: '<path d="M3 12h2l2-6 3 12 3-14 3 14 2-6h3"/>',
  general: '<circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/>',
  storage: '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v6c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/>'
};

document.querySelectorAll('[data-icon]').forEach((node) => {
  const path = iconPaths[node.dataset.icon] || iconPaths.more;
  node.classList.add('icon');
  node.setAttribute('aria-hidden', 'true');
  node.innerHTML = `<svg viewBox="0 0 24 24">${path}</svg>`;
});
document.querySelectorAll('[data-toggle]').forEach((toggle) => {
  toggle.addEventListener('click', () => {
    if (toggle.disabled) return;
    const enabled = toggle.classList.toggle('is-on');
    toggle.setAttribute('aria-pressed', String(enabled));
  });
});

document.querySelectorAll('.segmented').forEach((control) => {
  control.querySelectorAll('button').forEach((button) => {
    button.addEventListener('click', () => {
      control.querySelectorAll('button').forEach((item) => item.classList.remove('active'));
      button.classList.add('active');
    });
  });
});

let toastTimer;
const toast = document.querySelector('[data-toast-region]');

function showToast(message) {
  if (!toast) return;
  toast.querySelector('[data-toast-copy]').textContent = message;
  toast.classList.add('visible');
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => toast.classList.remove('visible'), 2400);
}

document.querySelectorAll('[data-toast-message]').forEach((button) => {
  button.addEventListener('click', () => showToast(button.dataset.toastMessage));
});

const timerNode = document.querySelector('[data-live-timer]');
if (timerNode) {
  let elapsed = Number(timerNode.dataset.seconds || 0);
  window.setInterval(() => {
    elapsed += 1;
    const hours = String(Math.floor(elapsed / 3600)).padStart(2, '0');
    const minutes = String(Math.floor((elapsed % 3600) / 60)).padStart(2, '0');
    const seconds = String(elapsed % 60).padStart(2, '0');
    timerNode.textContent = `${hours}:${minutes}:${seconds}`;
  }, 1000);
}

document.addEventListener('keydown', (event) => {
  if (event.metaKey && event.key.toLowerCase() === 'r') {
    const destination = document.body.dataset.recordShortcut;
    if (destination) {
      event.preventDefault();
      window.location.href = destination;
    }
  }

  if (event.metaKey && event.key === ',') {
    event.preventDefault();
    window.location.href = 'settings.html';
  }
});

// Interactive design prototype. No recording, transcription, export, or AI network request occurs.
(() => {
  const { EditorTimeline } = window.StudioEditorModel;
  const timeline = new EditorTimeline(342);
  const byId = id => document.getElementById(id);
  const words = [
    { id: 'w1', text: 'Сьогодні', start: 72.16, end: 72.48, sentence: 1 },
    { id: 'w2', text: 'ми', start: 72.49, end: 72.68, sentence: 1 },
    { id: 'w3', text: 'покажемо,', start: 72.70, end: 73.16, sentence: 1 },
    { id: 'w4', text: 'як', start: 73.20, end: 73.46, sentence: 1 },
    { id: 'w5', text: 'швидко', start: 73.47, end: 74.05, sentence: 1 },
    { id: 'w6', text: 'записати', start: 74.08, end: 74.45, sentence: 1 },
    { id: 'w7', text: 'відео.', start: 74.48, end: 74.75, sentence: 1 },
    { id: 'w8', text: 'Для', start: 76.10, end: 76.30, sentence: 2 },
    { id: 'w9', text: 'цього', start: 76.32, end: 76.58, sentence: 2 },
    { id: 'w10', text: 'ну,', start: 76.84, end: 77.09, sentence: 2, review: true },
    { id: 'w11', text: 'потрібно', start: 77.34, end: 77.79, sentence: 2 },
    { id: 'w12', text: 'натиснути', start: 77.82, end: 78.34, sentence: 2 },
    { id: 'w13', text: 'Record.', start: 78.36, end: 78.72, sentence: 2 },
  ];
  const pause = { start: 74.75, end: 76.10 };
  const workarea = byId('workarea');
  let viewStart = 68;
  let viewSpan = 16;
  let playhead = 72.16;
  let wordAnchor = null;
  let visibleWords = [];
  let proposal = null;
  let proposalCard = null;
  let reviewWord = null;
  let toastTimer;
  let selectionOrigin = 'timeline';
  const panelWidths = { chat: 290, transcript: 280 };

  function formatTime(seconds, milliseconds = false) {
    const totalMilliseconds = Math.round(seconds * 1000);
    const whole = Math.floor(totalMilliseconds / 1000);
    const mm = String(Math.floor(whole / 60)).padStart(2, '0');
    const ss = String(whole % 60).padStart(2, '0');
    return milliseconds ? mm + ':' + ss + '.' + String(totalMilliseconds % 1000).padStart(3, '0') : mm + ':' + ss;
  }

  function notify(text) {
    const toast = byId('toast');
    toast.textContent = text;
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('show'), 3300);
  }

  function visibleInterval(start, end) {
    const a = Math.max(start, viewStart);
    const b = Math.min(end, viewStart + viewSpan);
    return b > a ? { left: (a - viewStart) / viewSpan * 100, width: (b - a) / viewSpan * 100 } : null;
  }

  function addOverlay(container, className, start, end) {
    const area = visibleInterval(start, end);
    if (!area) return;
    const overlay = document.createElement('span');
    overlay.className = className;
    overlay.style.left = area.left + '%';
    overlay.style.width = area.width + '%';
    container.appendChild(overlay);
  }

  function proposedRanges() {
    if (!proposal) return [];
    if (proposal.type === 'cut') return [{ start: proposal.start, end: proposal.end }];
    if (proposal.type === 'reorder') {
      return [
        ...timeline.sourceRangeToOutput(72.16, 74.75),
        ...timeline.sourceRangeToOutput(76.10, 78.72),
      ];
    }
    return [];
  }

  function renderRuler() {
    const ruler = byId('rulerMarks');
    ruler.replaceChildren();
    if (timeline.duration === 0) return;
    const step = viewSpan <= 10 ? 1 : viewSpan <= 24 ? 2 : viewSpan <= 90 ? 10 : 60;
    for (let time = Math.ceil(viewStart / step) * step; time <= Math.min(timeline.duration, viewStart + viewSpan); time += step) {
      const tick = document.createElement('div');
      tick.className = 'ruler-tick';
      tick.style.left = (time - viewStart) / viewSpan * 100 + '%';
      const label = document.createElement('span');
      label.textContent = formatTime(time);
      tick.appendChild(label);
      ruler.appendChild(tick);
    }
  }

  function renderVideoTrack(container) {
    let offset = 0;
    for (const piece of timeline.pieces) {
      const length = piece.sourceEnd - piece.sourceStart;
      const area = visibleInterval(offset, offset + length);
      if (area) {
        const clip = document.createElement('div');
        clip.className = 'clip-piece';
        clip.style.left = area.left + '%';
        clip.style.width = area.width + '%';
        clip.title = 'Linked program video + audio · source ' + formatTime(piece.sourceStart, true) + '–' + formatTime(piece.sourceEnd, true);
        if (area.width > 14) {
          const label = document.createElement('span');
          label.textContent = 'Program';
          clip.appendChild(label);
        }
        container.appendChild(clip);
      }
      offset += length;
    }
  }

  function renderAudioTrack(container) {
    const bars = document.createElement('div');
    bars.className = 'wave-bars';
    for (let i = 0; i < 126; i++) {
      const outputTime = viewStart + (i + .5) / 126 * viewSpan;
      const sourceTime = timeline.outputToSource(outputTime);
      const bar = document.createElement('i');
      const silence = sourceTime !== null && sourceTime >= pause.start && sourceTime < pause.end;
      const level = sourceTime === null ? 0 : silence ? 8 : 15 + Math.abs(Math.sin(sourceTime * 6.1) * Math.cos(sourceTime * 2.7)) * 72;
      bar.style.height = level + '%';
      if (sourceTime === null) bar.style.opacity = '0';
      bars.appendChild(bar);
    }
    container.appendChild(bars);
  }

  function renderTimeline() {
    viewStart = Math.max(0, Math.min(viewStart, Math.max(0, timeline.duration - viewSpan)));
    byId('emptyPreview').hidden = timeline.duration !== 0;
    document.querySelector('.preview .sample-scene').hidden = timeline.duration === 0;
    byId('play').hidden = timeline.duration === 0;
    byId('playTransport').disabled = timeline.duration === 0;
    byId('outputDuration').textContent = '/ ' + formatTime(timeline.duration, true);
    byId('playheadTime').textContent = formatTime(playhead, true);
    byId('timelineWindow').textContent = formatTime(viewStart) + '–' + formatTime(Math.min(timeline.duration, viewStart + viewSpan)) + ' of ' + formatTime(timeline.duration);
    byId('cutSummary').textContent = timeline.undoStack.length
      ? 'Edited duration ' + formatTime(timeline.duration, true) + ' · source ' + formatTime(timeline.originalDuration)
      : 'Original duration ' + formatTime(timeline.originalDuration) + ' · no cuts';
    byId('undo').disabled = !timeline.undoStack.length;
    byId('redo').disabled = !timeline.redoStack.length;
    renderRuler();

    for (const id of ['videoTrack', 'audioTrack']) {
      const container = byId(id);
      container.replaceChildren();
      if (id === 'videoTrack') renderVideoTrack(container);
      else renderAudioTrack(container);
      if (timeline.selection) addOverlay(container, 'selection-overlay', timeline.selection.start, timeline.selection.end);
      for (const range of proposedRanges()) addOverlay(container, 'proposal-overlay', range.start, range.end);
      const marker = visibleInterval(playhead, playhead + .0001);
      if (marker) {
        const line = document.createElement('span');
        line.className = 'playhead-line';
        line.style.left = marker.left + '%';
        container.appendChild(line);
      }
      container.setAttribute('aria-valuemax', String(Math.round(timeline.duration * 100) / 100));
      container.setAttribute('aria-valuenow', String(Math.round(playhead * 100) / 100));
      container.setAttribute('aria-valuetext', formatTime(playhead, true) + ' playhead; ' +
        (timeline.selection ? formatTime(timeline.selection.start, true) + ' to ' + formatTime(timeline.selection.end, true) + ' selected on video and audio' : 'no range selected'));
    }
  }

  function wordView(word) {
    const ranges = timeline.sourceRangeToOutput(word.start, word.end);
    const retained = ranges.reduce((sum, range) => sum + range.end - range.start, 0);
    const original = word.end - word.start;
    if (retained < original * .5 || !ranges.length) return null;
    return {
      ...word,
      outputStart: ranges[0].start,
      outputEnd: ranges[ranges.length - 1].end,
      partial: retained < original - .01,
    };
  }

  function renderTranscript() {
    visibleWords = words.map(wordView).filter(Boolean).sort((a, b) => a.outputStart - b.outputStart);
    const rows = [];
    for (const sentence of [1, 2]) {
      const sentenceWords = visibleWords.filter(word => word.sentence === sentence);
      if (sentenceWords.length) rows.push({ type: 'sentence', start: sentenceWords[0].outputStart, words: sentenceWords });
    }
    const pauseRanges = timeline.sourceRangeToOutput(pause.start, pause.end);
    for (const range of pauseRanges) rows.push({ type: 'pause', start: range.start, range });
    rows.sort((a, b) => a.start - b.start);

    const container = byId('transcriptRows');
    container.replaceChildren();
    if (!rows.length) {
      const empty = document.createElement('p');
      empty.className = 'transcript-empty';
      empty.textContent = 'No spoken words remain in this edit. The original recording is preserved.';
      container.appendChild(empty);
    }
    for (const row of rows) {
      const line = document.createElement('div');
      line.className = 'transcript-line';
      const stamp = document.createElement('span');
      stamp.className = 'stamp';
      stamp.textContent = formatTime(row.start);
      const content = document.createElement('div');
      content.className = 'transcript-words';
      if (row.type === 'pause') {
        const button = document.createElement('button');
        button.className = 'silence-button';
        button.type = 'button';
        button.dataset.outputStart = row.range.start;
        button.dataset.outputEnd = row.range.end;
        button.textContent = 'Pause · ' + (row.range.end - row.range.start).toFixed(2) + ' s';
        button.setAttribute('aria-label', button.textContent + ' at ' + formatTime(row.range.start, true));
        content.appendChild(button);
      } else {
        for (const word of row.words) {
          const button = document.createElement('button');
          button.className = 'word' + (word.review ? ' review' : '') + (word.partial ? ' partial' : '');
          button.type = 'button';
          button.dataset.wordId = word.id;
          button.textContent = word.text;
          button.title = 'Output ' + formatTime(word.outputStart, true) + '–' + formatTime(word.outputEnd, true) +
            ' · source ' + formatTime(word.start, true) + '–' + formatTime(word.end, true);
          button.setAttribute('aria-label', word.text + ', output ' + formatTime(word.outputStart, true) + ' to ' + formatTime(word.outputEnd, true) + (word.review ? ', timing needs review' : ''));
          content.appendChild(button);
          content.append(' ');
        }
      }
      line.append(stamp, content);
      container.appendChild(line);
    }
    const removed = words.filter(word => !wordView(word));
    byId('removedSection').hidden = removed.length === 0;
    byId('removedWords').textContent = removed.map(word => word.text).join(' ');
    byId('transcriptCount').textContent = visibleWords.length + ' words · edited order';
    applyTranscriptSearch();
    syncSelection();
  }

  function selectedWords() {
    const selection = timeline.selection;
    return selection ? visibleWords.filter(word => word.outputStart < selection.end && word.outputEnd > selection.start) : [];
  }

  function syncSelection() {
    const selection = timeline.selection;
    const chosen = selectedWords();
    const chosenIds = new Set(chosen.map(word => word.id));
    for (const button of document.querySelectorAll('.word')) {
      const active = chosenIds.has(button.dataset.wordId);
      button.classList.toggle('selected', active);
      button.setAttribute('aria-pressed', String(active));
      const word = visibleWords.find(item => item.id === button.dataset.wordId);
      button.classList.toggle('proposed', !!word && proposedRanges().some(range => word.outputStart < range.end && word.outputEnd > range.start));
    }
    for (const button of document.querySelectorAll('.silence-button')) {
      const start = Number(button.dataset.outputStart);
      const end = Number(button.dataset.outputEnd);
      button.classList.toggle('selected', !!selection && start < selection.end && end > selection.start);
      button.classList.toggle('proposed', proposedRanges().some(range => start < range.end && end > range.start));
    }
    byId('cutRange').disabled = !selection || selectionOrigin === 'transcript' && chosen.some(word => word.review);
    byId('cutWords').disabled = !chosen.length || chosen.some(word => word.review);
    byId('reviewTiming').hidden = !chosen.some(word => word.review);
    byId('clearScope').hidden = !selection;
    byId('assistantScope').textContent = selection
      ? formatTime(selection.start, true) + '–' + formatTime(selection.end, true) + ' · video + audio'
      : 'Whole video';
    byId('selectionSummary').textContent = selection
      ? 'Selected ' + formatTime(selection.start, true) + '–' + formatTime(selection.end, true) + ' · video + audio'
      : 'Drag on video or audio to select both.';
    byId('wordTimingDetails').textContent = chosen.length === 1
      ? chosen[0].text + ' · ' + formatTime(chosen[0].outputStart, true) + '–' + formatTime(chosen[0].outputEnd, true) + (chosen[0].review ? ' · review timing' : '')
      : chosen.length > 1 ? chosen.length + ' words selected' : 'Select a word for its exact time.';
    renderTimeline();
  }

  function selectOutputRange(start, end, origin = 'timeline') {
    selectionOrigin = origin;
    timeline.select(start, end);
    syncSelection();
  }

  function selectWord(word, extend) {
    if (extend && wordAnchor) {
      const first = visibleWords.findIndex(item => item.id === wordAnchor);
      const second = visibleWords.findIndex(item => item.id === word.id);
      if (first >= 0 && second >= 0) {
        const slice = visibleWords.slice(Math.min(first, second), Math.max(first, second) + 1);
        selectOutputRange(Math.min(...slice.map(item => item.outputStart)), Math.max(...slice.map(item => item.outputEnd)), 'transcript');
      }
    } else {
      wordAnchor = word.id;
      selectOutputRange(word.outputStart, word.outputEnd, 'transcript');
    }
    playhead = word.outputStart;
    renderTimeline();
  }

  function afterEdit(label) {
    proposal = null;
    if (proposalCard) proposalCard.remove();
    proposalCard = null;
    playhead = Math.min(playhead, timeline.duration);
    renderTranscript();
    notify(label + ' · linked video and audio updated. Original preserved.');
  }

  function removeSelected(asWords = false) {
    if (!timeline.selection) return;
    if ((asWords || selectionOrigin === 'transcript') && selectedWords().some(word => word.review)) {
      notify('Review the dotted word timing before removing it from the transcript.');
      return;
    }
    if (timeline.cutSelection()) afterEdit('Sample cut');
  }

  function appendMessage(role, content) {
    const message = document.createElement('div');
    message.className = 'chat-message ' + (role === 'user' ? 'user-message' : 'assistant-message');
    const byline = document.createElement('span');
    byline.className = 'message-byline';
    byline.textContent = role === 'user' ? 'You' : 'Assistant · sample';
    const paragraph = document.createElement('p');
    paragraph.textContent = content;
    message.append(byline, paragraph);
    byId('chatHistory').appendChild(message);
    message.scrollIntoView({ block: 'nearest' });
    return message;
  }

  function dismissProposal() {
    proposal = null;
    if (proposalCard) proposalCard.remove();
    proposalCard = null;
    syncSelection();
  }

  function showProposal(next) {
    dismissProposal();
    proposal = next;
    const card = document.createElement('div');
    card.className = 'proposal-card';
    const title = document.createElement('strong');
    title.textContent = next.title;
    const description = document.createElement('p');
    description.textContent = next.description;
    const actions = document.createElement('div');
    actions.className = 'proposal-actions';
    if (next.type === 'text') {
      const copy = document.createElement('button');
      copy.className = 'mini primary';
      copy.type = 'button';
      copy.textContent = 'Copy text';
      copy.onclick = async () => {
        try { await navigator.clipboard.writeText(next.description); notify('Sample text copied.'); }
        catch { notify('Clipboard is unavailable in this preview.'); }
      };
      actions.appendChild(copy);
    } else {
      const inspect = document.createElement('button');
      inspect.className = 'mini';
      inspect.type = 'button';
      inspect.textContent = 'Show on timeline';
      inspect.onclick = () => {
        const range = proposedRanges()[0];
        if (range) { viewStart = Math.max(0, range.start - viewSpan / 3); renderTimeline(); }
      };
      const apply = document.createElement('button');
      apply.className = 'mini primary';
      apply.type = 'button';
      apply.textContent = 'Apply edit';
      apply.onclick = () => {
        if (next !== proposal) return;
        if (next.type === 'cut') {
          timeline.select(next.start, next.end);
          if (!timeline.cutSelection()) return notify('This range has already been removed.');
        } else if (next.type === 'reorder') {
          if (!timeline.moveSourceRangeBefore(76.10, 78.72, 72.16)) return notify('These recorded phrases are no longer available as complete clips.');
        }
        afterEdit('Sample AI proposal applied');
      };
      actions.append(inspect, apply);
    }
    const dismiss = document.createElement('button');
    dismiss.className = 'mini';
    dismiss.type = 'button';
    dismiss.textContent = 'Dismiss';
    dismiss.onclick = dismissProposal;
    actions.appendChild(dismiss);
    card.append(title, description, actions);
    byId('chatHistory').appendChild(card);
    proposalCard = card;
    card.scrollIntoView({ block: 'nearest' });
    syncSelection();
  }

  function handlePrompt(prompt) {
    const query = prompt.toLocaleLowerCase();
    appendMessage('user', prompt);
    if (query.includes('camera') || query.includes('камер')) {
      dismissProposal();
      appendMessage('assistant', 'This project has a composed program movie. Its camera cannot be moved as an independent source.');
      return;
    }
    if (query.includes('pause') || query.includes('silence') || query.includes('gap') || query.includes('пауз') || query.includes('тиш')) {
      const ranges = timeline.sourceRangeToOutput(pause.start, pause.end);
      const gap = ranges[0];
      if (!gap || timeline.selection && (timeline.selection.start > gap.start || timeline.selection.end < gap.end)) {
        dismissProposal();
        appendMessage('assistant', 'No complete sample pause is available in the current scope.');
        return;
      }
      showProposal({ type: 'cut', title: 'Remove the long pause', description: formatTime(gap.start, true) + '–' + formatTime(gap.end, true) + ' · removes 1.35 s from video and audio.', start: gap.start, end: gap.end });
      return;
    }
    if (query.includes('reorder') || query.includes('move') || query.includes('перестав') || query.includes('поміня')) {
      const first = timeline.sourceRangeToOutput(72.16, 74.75);
      const second = timeline.sourceRangeToOutput(76.10, 78.72);
      if (first.length !== 1 || second.length !== 1 ||
          Math.abs(first[0].end - first[0].start - (74.75 - 72.16)) > .001 ||
          Math.abs(second[0].end - second[0].start - (78.72 - 76.10)) > .001) {
        dismissProposal();
        appendMessage('assistant', 'The two complete sample phrases are no longer available for reordering. Undo a cut to restore them.');
        return;
      }
      if (timeline.selection && (timeline.selection.start > Math.min(first[0].start, second[0].start) ||
          timeline.selection.end < Math.max(first[0].end, second[0].end))) {
        dismissProposal();
        appendMessage('assistant', 'Select both recorded phrases or clear the selection to preview this reorder.');
        return;
      }
      showProposal({ type: 'reorder', title: 'Reorder recorded phrases', description: 'Move “Для цього… Record.” before “Сьогодні… відео.” The existing picture and sound move together; no new speech is generated.' });
      return;
    }
    if (query.includes('analy') || query.includes('аналіз')) {
      showProposal({ type: 'text', title: 'Sentence analysis · text only', description: 'The first sentence explains the goal. A 1.35 s pause separates it from the instruction. “ну,” is a filler with timing that needs review. Suggested next steps: review and remove the pause, then consider a shorter retake script. No media change has been applied.' });
      return;
    }
    if (query.includes('rewrite') || query.includes('rephrase') || query.includes('improve') || query.includes('format') || query.includes('shorten') || query.includes('перефраз') || query.includes('покращ') || query.includes('формат') || query.includes('скороч')) {
      const chosen = selectedWords();
      const sentenceOne = chosen.length && chosen.every(word => word.sentence === 1);
      const sentenceTwo = chosen.length && chosen.every(word => word.sentence === 2);
      const script = sentenceOne ? 'Сьогодні покажемо, як швидко записати відео.'
        : sentenceTwo ? 'Щоб почати, натисніть Record.'
          : 'Сьогодні покажемо, як швидко записати відео. Для цього натисніть Record.';
      showProposal({ type: 'text', title: 'Retake script · text only', description: script + '\n\nThis is a script suggestion. The recorded voice and video remain unchanged.' });
      return;
    }
    if (query.includes('title') || query.includes('description') || query.includes('назв') || query.includes('опис')) {
      showProposal({ type: 'text', title: 'Titles and description · text only', description: '1. Record a product walkthrough in minutes\n2. A simple guide to Studio Recorder\n3. From screen capture to finished demo\n\nDescription: See how to capture your screen and camera, then refine the recording in Studio Recorder.' });
      return;
    }
    if (query.includes('remove') || query.includes('cut') || query.includes('delete') || query.includes('виріз') || query.includes('видал')) {
      if (!timeline.selection) {
        dismissProposal();
        appendMessage('assistant', 'Select a range on either track or choose words in the transcript first.');
        return;
      }
      if (selectedWords().some(word => word.review)) {
        dismissProposal();
        appendMessage('assistant', 'Review the dotted word timing before using it for a transcript cut.');
        return;
      }
      showProposal({ type: 'cut', title: 'Remove selected range', description: formatTime(timeline.selection.start, true) + '–' + formatTime(timeline.selection.end, true) + ' · cuts linked picture and sound.', ...timeline.selection });
      return;
    }
    dismissProposal();
    appendMessage('assistant', 'This preview can show pause cuts, recorded phrase order, retake wording, and title or description ideas. No request was sent to OpenRouter.');
  }

  function applyTranscriptSearch() {
    const query = byId('transcriptSearch').value.trim().toLocaleLowerCase();
    for (const line of byId('transcriptRows').querySelectorAll('.transcript-line')) {
      line.hidden = !!query && !line.textContent.toLocaleLowerCase().includes(query);
    }
  }

  function setRoute(route) {
    byId('editorScreen').hidden = route !== 'editor';
    byId('projectsScreen').hidden = route !== 'projects';
    byId('studioScreen').hidden = route !== 'studio';
    byId('projectsNav').classList.toggle('active', route === 'projects');
    byId('studioNav').classList.toggle('active', route === 'studio');
    byId('projectTitle').hidden = route !== 'editor';
    byId('projectInfoButton').hidden = route !== 'editor';
    byId('export').hidden = route !== 'editor';
    byId('jobsDrawer').hidden = true;
    byId('jobsButton').setAttribute('aria-expanded', 'false');
  }

  function resizePanel(side, amount) {
    const width = workarea.getBoundingClientRect().width;
    const other = parseFloat(getComputedStyle(workarea).getPropertyValue(side === 'chat' ? '--transcript-width' : '--chat-width'));
    const min = side === 'chat' ? 240 : 260;
    const max = Math.min(side === 'chat' ? 350 : 350, width - other - 500);
    const value = Math.max(min, Math.min(max, amount));
    panelWidths[side] = value;
    workarea.style.setProperty(side === 'chat' ? '--chat-width' : '--transcript-width', value + 'px');
    byId(side === 'chat' ? 'chatResizer' : 'transcriptResizer').setAttribute('aria-valuenow', String(Math.round(value)));
  }

  function attachResizer(id, side) {
    const handle = byId(id);
    handle.addEventListener('pointerdown', event => {
      handle.setPointerCapture(event.pointerId);
      const move = moveEvent => {
        const rect = workarea.getBoundingClientRect();
        resizePanel(side, side === 'chat' ? moveEvent.clientX - rect.left : rect.right - moveEvent.clientX);
      };
      const stop = () => { handle.removeEventListener('pointermove', move); handle.removeEventListener('pointerup', stop); };
      handle.addEventListener('pointermove', move);
      handle.addEventListener('pointerup', stop);
    });
    handle.addEventListener('keydown', event => {
      if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
      event.preventDefault();
      const current = parseFloat(getComputedStyle(workarea).getPropertyValue(side === 'chat' ? '--chat-width' : '--transcript-width'));
      resizePanel(side, current + (event.key === 'ArrowRight' ? 16 : -16) * (side === 'chat' ? 1 : -1));
    });
  }

  function togglePanel(side) {
    const panel = byId(side === 'chat' ? 'collapseChat' : 'collapseTranscript').closest('aside');
    const button = byId(side === 'chat' ? 'collapseChat' : 'collapseTranscript');
    const collapsed = panel.classList.toggle('is-collapsed');
    workarea.classList.toggle(side + '-collapsed', collapsed);
    if (collapsed) {
      workarea.style.setProperty(side === 'chat' ? '--chat-width' : '--transcript-width', '44px');
    } else {
      const otherSide = side === 'chat' ? 'transcript' : 'chat';
      const otherWidth = parseFloat(getComputedStyle(workarea).getPropertyValue(otherSide === 'chat' ? '--chat-width' : '--transcript-width'));
      const roomForOther = workarea.getBoundingClientRect().width - panelWidths[side] - 500;
      if (!workarea.classList.contains(otherSide + '-collapsed') && otherWidth > roomForOther) {
        resizePanel(otherSide, roomForOther);
      }
      resizePanel(side, panelWidths[side]);
    }
    button.textContent = side === 'chat' ? collapsed ? '›' : '‹' : collapsed ? '‹' : '›';
    button.setAttribute('aria-expanded', String(!collapsed));
    button.setAttribute('aria-label', (collapsed ? 'Expand ' : 'Collapse ') + (side === 'chat' ? 'chat' : 'transcript'));
  }

  for (const id of ['videoTrack', 'audioTrack']) {
    const track = byId(id);
    let dragStart = null;
    const outputAt = clientX => {
      const rect = track.getBoundingClientRect();
      return Math.max(0, Math.min(timeline.duration, viewStart + (clientX - rect.left) / rect.width * viewSpan));
    };
    track.addEventListener('pointerdown', event => {
      if (event.button !== 0) return;
      dragStart = outputAt(event.clientX);
      track.setPointerCapture(event.pointerId);
      playhead = dragStart;
      timeline.clearSelection();
      syncSelection();
    });
    track.addEventListener('pointermove', event => {
      if (dragStart === null) return;
      selectOutputRange(dragStart, outputAt(event.clientX));
    });
    track.addEventListener('pointerup', event => {
      if (dragStart === null) return;
      const end = outputAt(event.clientX);
      selectOutputRange(dragStart, end);
      if (!timeline.selection) playhead = end;
      dragStart = null;
      renderTimeline();
    });
    track.addEventListener('pointercancel', () => { dragStart = null; });
    track.addEventListener('keydown', event => {
      if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
      event.preventDefault();
      const prior = playhead;
      playhead = Math.max(0, Math.min(timeline.duration, playhead + (event.key === 'ArrowRight' ? .1 : -.1)));
      if (event.shiftKey) selectOutputRange(timeline.selection ? timeline.selection.start : prior, playhead);
      else { timeline.clearSelection(); syncSelection(); }
      renderTimeline();
    });
  }

  byId('rulerMarks').addEventListener('click', event => {
    const rect = byId('rulerMarks').getBoundingClientRect();
    playhead = Math.max(0, Math.min(timeline.duration, viewStart + (event.clientX - rect.left) / rect.width * viewSpan));
    renderTimeline();
  });
  byId('transcriptRows').addEventListener('click', event => {
    const wordButton = event.target.closest('.word');
    if (wordButton) {
      const word = visibleWords.find(item => item.id === wordButton.dataset.wordId);
      if (word) selectWord(word, event.shiftKey);
      return;
    }
    const pauseButton = event.target.closest('.silence-button');
    if (pauseButton) selectOutputRange(Number(pauseButton.dataset.outputStart), Number(pauseButton.dataset.outputEnd), 'transcript');
  });
  byId('transcriptRows').addEventListener('keydown', event => {
    if (!event.target.matches('.word') || !['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
    event.preventDefault();
    const index = visibleWords.findIndex(word => word.id === event.target.dataset.wordId);
    const next = visibleWords[Math.max(0, Math.min(visibleWords.length - 1, index + (event.key === 'ArrowRight' ? 1 : -1)))];
    const button = byId('transcriptRows').querySelector('[data-word-id="' + next.id + '"]');
    button.focus();
    selectWord(next, event.shiftKey);
  });
  byId('transcriptSearch').addEventListener('input', applyTranscriptSearch);
  byId('clearScope').onclick = () => { timeline.clearSelection(); wordAnchor = null; selectionOrigin = 'timeline'; syncSelection(); };
  byId('cutRange').onclick = () => removeSelected();
  byId('cutWords').onclick = () => removeSelected(true);
  byId('undo').onclick = () => { if (timeline.undo()) afterEdit('Undo'); };
  byId('redo').onclick = () => { if (timeline.redo()) afterEdit('Redo'); };
  byId('zoomIn').onclick = () => { viewSpan = Math.max(4, viewSpan / 2); viewStart = Math.max(0, playhead - viewSpan / 2); renderTimeline(); };
  byId('zoomOut').onclick = () => { viewSpan = Math.max(4, Math.min(timeline.duration, viewSpan * 2)); viewStart = Math.max(0, playhead - viewSpan / 2); renderTimeline(); };
  byId('zoomFit').onclick = () => { viewSpan = Math.max(4, timeline.duration); viewStart = 0; renderTimeline(); };
  for (const id of ['play', 'playTransport']) byId(id).onclick = () => notify('Sample artwork only. No media playback in this design prototype.');
  byId('transcribe').onclick = () => notify('Sample transcript only. The prototype does not start Whisper.');

  byId('reviewTiming').onclick = () => {
    reviewWord = selectedWords().find(word => word.review);
    if (!reviewWord) return;
    byId('timingStart').value = reviewWord.start;
    byId('timingEnd').value = reviewWord.end;
    byId('timingEditor').hidden = false;
  };
  byId('confirmTiming').onclick = () => {
    const start = Number(byId('timingStart').value);
    const end = Number(byId('timingEnd').value);
    if (!reviewWord || !Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end <= start || end > timeline.originalDuration) {
      return notify('Enter valid source boundaries within the original recording.');
    }
    const original = words.find(word => word.id === reviewWord.id);
    original.start = start;
    original.end = end;
    original.review = false;
    byId('timingEditor').hidden = true;
    renderTranscript();
    const updated = visibleWords.find(word => word.id === reviewWord.id);
    if (updated) selectOutputRange(updated.outputStart, updated.outputEnd, 'transcript');
    reviewWord = null;
    notify('Sample timing confirmed. No audio was analyzed.');
  };

  byId('assistantForm').addEventListener('submit', event => {
    event.preventDefault();
    const field = byId('assistantPrompt');
    const prompt = field.value.trim();
    if (!prompt) return;
    field.value = '';
    handlePrompt(prompt);
  });
  byId('assistantPrompt').addEventListener('keydown', event => {
    if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); byId('assistantForm').requestSubmit(); }
  });
  document.querySelectorAll('[data-prompt]').forEach(button => button.onclick = () => handlePrompt(button.dataset.prompt));
  attachResizer('chatResizer', 'chat');
  attachResizer('transcriptResizer', 'transcript');
  byId('collapseChat').onclick = () => togglePanel('chat');
  byId('collapseTranscript').onclick = () => togglePanel('transcript');

  byId('projectsNav').onclick = () => setRoute('projects');
  byId('studioNav').onclick = () => setRoute('studio');
  byId('openProject').onclick = () => setRoute('editor');
  byId('processingProject').onclick = () => { byId('jobsDrawer').hidden = false; byId('jobsButton').setAttribute('aria-expanded', 'true'); };
  byId('projectSearch').oninput = event => document.querySelectorAll('.project-item').forEach(item => { item.hidden = !item.textContent.toLocaleLowerCase().includes(event.target.value.toLocaleLowerCase()); });
  byId('jobsButton').onclick = () => {
    byId('jobsDrawer').hidden = !byId('jobsDrawer').hidden;
    byId('jobsButton').setAttribute('aria-expanded', String(!byId('jobsDrawer').hidden));
  };
  byId('closeJobs').onclick = () => { byId('jobsDrawer').hidden = true; byId('jobsButton').setAttribute('aria-expanded', 'false'); };
  byId('export').onclick = () => { byId('jobsDrawer').hidden = false; byId('jobsButton').setAttribute('aria-expanded', 'true'); notify('Sample export appears in Jobs. No file was created.'); };

  const projectDetails = byId('projectDetailsDialog');
  byId('projectInfoButton').onclick = () => projectDetails.showModal();
  byId('closeProjectDetails').onclick = () => projectDetails.close();
  for (const id of ['rawReveal', 'rawShare', 'saveFrame', 'gifButton']) {
    byId(id).onclick = () => {
      const label = byId(id).textContent;
      projectDetails.close();
      notify(label + ' is an existing app action shown for design context. This prototype creates no file.');
    };
  }
  document.querySelectorAll('[data-sample-tool]').forEach(button => button.onclick = () => {
    byId('timelineTools').open = false;
    notify(button.dataset.sampleTool + ' is shown for design context. No media was changed.');
  });
  const settingsDialog = byId('settingsDialog');
  byId('settingsNav').onclick = () => settingsDialog.showModal();
  byId('closeSettings').onclick = () => settingsDialog.close();
  const settingsContent = {
    General: ['Appearance', 'Theme', 'System'],
    Audio: ['Capture defaults', 'Microphone', 'Built-in', 'System audio', 'On'],
    Streaming: ['Streaming', 'YouTube', 'Not configured in this build', 'Output', 'Save local recording'],
    Storage: ['Storage', 'New projects', 'Movies / Studio Recorder'],
    Shortcuts: ['Keyboard', 'Recording controls', 'Command + Shift + C', 'Scenes', 'Option + 1 through 9'],
    AI: ['Assistant connection', 'Provider', 'OpenRouter · bring your own key', 'Key storage', 'macOS Keychain in the native app', 'Prototype', 'Sample replies only; no request sent'],
  };
  document.querySelectorAll('[data-settings]').forEach(button => button.onclick = () => {
    document.querySelectorAll('[data-settings]').forEach(item => item.classList.toggle('active', item === button));
    byId('settingsTitle').textContent = button.dataset.settings;
    const [heading, ...values] = settingsContent[button.dataset.settings];
    const body = byId('settingsBody');
    body.replaceChildren();
    const title = document.createElement('p');
    title.textContent = heading;
    body.appendChild(title);
    for (let i = 0; i < values.length; i += 2) {
      const row = document.createElement('div');
      row.className = 'settings-row';
      const label = document.createElement('span');
      label.textContent = values[i];
      const value = document.createElement('strong');
      value.textContent = values[i + 1];
      row.append(label, value);
      body.appendChild(row);
    }
  });
  const recordingDialog = byId('newRecordingDialog');
  byId('newRecordingButton').onclick = () => recordingDialog.showModal();
  byId('newFromProjects').onclick = () => recordingDialog.showModal();
  byId('closeNewRecording').onclick = () => recordingDialog.close();
  byId('cancelNewRecording').onclick = () => recordingDialog.close();
  byId('recordingName').oninput = event => { byId('createNewRecording').disabled = !event.target.value.trim(); };
  document.querySelectorAll('.profile-choice').forEach(button => button.onclick = () => document.querySelectorAll('.profile-choice').forEach(item => item.classList.toggle('active', item === button)));
  byId('createNewRecording').onclick = () => {
    const editable = document.querySelector('.profile-choice.active').textContent.includes('Editable tracks');
    document.querySelector('.studio-heading p').textContent = (editable ? 'Editable tracks' : 'Product demo') + ' · 1920 × 1080 · 30 fps';
    byId('studioRetention').textContent = editable ? 'Editable tracks' : 'Program movie';
    recordingDialog.close();
    setRoute('studio');
    notify('Sample session only. No recording was created.');
  };
  document.querySelectorAll('.scene-button').forEach(button => button.onclick = () => {
    document.querySelectorAll('.scene-button').forEach(item => item.classList.toggle('active', item === button));
    document.querySelector('.studio-stage .sample-screen').hidden = button.textContent === 'Camera';
    document.querySelector('.studio-stage .scene-camera').hidden = button.textContent === 'Screen';
    document.querySelector('.studio-stage').classList.toggle('camera-only', button.textContent === 'Camera');
  });
  for (const id of ['sampleRecord', 'profilesButton', 'newSceneButton']) byId(id).onclick = () => notify('Sample Studio control. No recording or scene was created.');

  document.addEventListener('keydown', event => {
    const typing = ['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName);
    if (event.key === 'Escape') {
      if (!byId('jobsDrawer').hidden) byId('closeJobs').click();
      else if (proposal) dismissProposal();
      else if (timeline.selection) { timeline.clearSelection(); syncSelection(); }
    }
    if (typing) return;
    if ((event.key === 'Delete' || event.key === 'Backspace') && timeline.selection) { event.preventDefault(); removeSelected(); }
    if (event.metaKey && event.key.toLowerCase() === 'z') { event.preventDefault(); byId(event.shiftKey ? 'redo' : 'undo').click(); }
    if (event.metaKey && event.key.toLowerCase() === 'f' && !byId('editorScreen').hidden) { event.preventDefault(); byId('transcriptSearch').focus(); }
  });

  setRoute('editor');
  renderTranscript();
})();

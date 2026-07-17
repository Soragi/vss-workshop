const workshopConfig = window.VSS_WORKSHOP_CONFIG || { title: 'VSS AI Advisor Workshop' };
document.title = workshopConfig.title;
document.querySelector('#appTitle').textContent = workshopConfig.title;

const state = {
  videos: [],
  selectedVideo: null,
  sending: false,
};

const elements = {
  advisorStatus: document.querySelector('#advisorStatus'),
  chatForm: document.querySelector('#chatForm'),
  chatInput: document.querySelector('#chatInput'),
  conversation: document.querySelector('#conversation'),
  promptChips: Array.from(document.querySelectorAll('.prompt-chip')),
  selectedVideo: document.querySelector('#selectedVideo'),
  sendButton: document.querySelector('#sendButton'),
  uploadInput: document.querySelector('#videoUpload'),
  uploadStatus: document.querySelector('#uploadStatus'),
  videoCardTemplate: document.querySelector('#videoCardTemplate'),
  videoGrid: document.querySelector('#videoGrid'),
};

function setAdvisorStatus(message) {
  elements.advisorStatus.textContent = message;
}

function setUploadStatus(message, isError = false) {
  elements.uploadStatus.hidden = !message;
  elements.uploadStatus.textContent = message || '';
  elements.uploadStatus.classList.toggle('error', isError);
}

function filenameWithoutExtension(filename) {
  return filename.replace(/\.[^/.]+$/, '');
}

function safeUploadFilename(filename) {
  const safe = filename.replace(/[^A-Za-z0-9._-]/g, '_');
  return safe || 'workshop-video.mp4';
}

function describeError(response, fallback) {
  return response.json()
    .then((body) => body.detail || body.message || fallback)
    .catch(() => fallback);
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  if (!response.ok) {
    throw new Error(await describeError(response, `Request failed (${response.status}).`));
  }
  return response.json();
}

function refreshControls() {
  const enabled = Boolean(state.selectedVideo) && !state.sending;
  elements.chatInput.disabled = !enabled;
  elements.sendButton.disabled = !enabled;
  elements.promptChips.forEach((button) => {
    button.disabled = !enabled;
  });
}

function renderSelectedVideo() {
  const target = elements.selectedVideo;
  target.replaceChildren();

  if (!state.selectedVideo) {
    target.className = 'selected-video-empty';
    const title = document.createElement('strong');
    title.textContent = 'Select a video';
    const copy = document.createElement('span');
    copy.textContent = 'Choose a card on the right to give the advisor context.';
    target.append(title, copy);
    refreshControls();
    return;
  }

  target.className = 'selected-video-active';
  const badge = document.createElement('span');
  badge.className = 'selected-video-badge';
  badge.textContent = 'MP4';
  const details = document.createElement('div');
  const title = document.createElement('strong');
  title.textContent = state.selectedVideo.name;
  const copy = document.createElement('span');
  copy.textContent = 'Attached to this conversation';
  details.append(title, copy);
  target.append(badge, details);
  refreshControls();
}

function renderVideos() {
  elements.videoGrid.replaceChildren();

  if (state.videos.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'empty-library';
    const title = document.createElement('strong');
    title.textContent = 'Upload your first workshop video';
    const copy = document.createElement('span');
    copy.textContent = 'Use a short H.264 MP4, then select it to start a visual Q&A conversation.';
    empty.append(title, copy);
    elements.videoGrid.append(empty);
    return;
  }

  for (const video of state.videos) {
    const card = elements.videoCardTemplate.content.firstElementChild.cloneNode(true);
    const isSelected = video.sensorId === state.selectedVideo?.sensorId;
    card.classList.toggle('selected', isSelected);
    card.querySelector('.video-name').textContent = video.name;
    card.setAttribute('aria-pressed', String(isSelected));
    card.addEventListener('click', () => {
      state.selectedVideo = video;
      renderSelectedVideo();
      renderVideos();
      setAdvisorStatus(`Video context set to ${video.name}.`);
      elements.chatInput.focus();
    });
    elements.videoGrid.append(card);
  }
}

async function loadVideos({ preserveSelection = true } = {}) {
  try {
    const videos = await fetchJson('/vst/api/v1/sensor/list');
    state.videos = Array.isArray(videos)
      ? videos
          .filter((video) => video.type === 'sensor_file')
          .map((video) => ({
            name: video.name || 'Untitled video',
            sensorId: video.sensorId,
            state: video.state || 'unknown',
          }))
      : [];

    if (preserveSelection && state.selectedVideo) {
      state.selectedVideo = state.videos.find((video) => video.sensorId === state.selectedVideo.sensorId) || null;
    }
    renderSelectedVideo();
    renderVideos();
  } catch (error) {
    elements.videoGrid.replaceChildren();
    const empty = document.createElement('div');
    empty.className = 'empty-library';
    const title = document.createElement('strong');
    title.textContent = 'Videos are not available yet';
    const copy = document.createElement('span');
    copy.textContent = error.message;
    empty.append(title, copy);
    elements.videoGrid.append(empty);
  }
}

function appendMessage(role, text) {
  const empty = elements.conversation.querySelector('.empty-conversation');
  if (empty) empty.remove();
  const message = document.createElement('article');
  message.className = `message message-${role}`;
  const label = document.createElement('span');
  label.className = 'message-label';
  label.textContent = role === 'advisor' ? 'AI VIDEO ADVISOR' : 'YOU';
  const content = document.createElement('div');
  content.textContent = text;
  message.append(label, content);
  elements.conversation.append(message);
  elements.conversation.scrollTop = elements.conversation.scrollHeight;
}

function buildAdvisorRequest(question) {
  const { name, sensorId } = state.selectedVideo;
  return [
    `The selected workshop video is named "${name}" (VST sensor ID: ${sensorId}).`,
    'Use this video as the primary context for the request and provide timestamps when useful.',
    question,
  ].join('\n\n');
}

async function askAdvisor(question) {
  const trimmedQuestion = question.trim();
  if (!state.selectedVideo || !trimmedQuestion || state.sending) return;

  state.sending = true;
  refreshControls();
  appendMessage('user', trimmedQuestion);
  elements.chatInput.value = '';
  setAdvisorStatus('The advisor is analyzing the selected video…');

  try {
    const response = await fetchJson('/generate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ input_message: buildAdvisorRequest(trimmedQuestion) }),
    });
    appendMessage('advisor', response.value || 'The advisor returned an empty response.');
    setAdvisorStatus('Ready for another question.');
  } catch (error) {
    appendMessage('advisor', `I could not complete that request: ${error.message}`);
    setAdvisorStatus('Try again after confirming that the video is ready.');
  } finally {
    state.sending = false;
    refreshControls();
    elements.chatInput.focus();
  }
}

async function uploadVideo(file) {
  if (!file) return;
  if (file.type && file.type !== 'video/mp4') {
    setUploadStatus('Choose an MP4 file for this workshop.', true);
    return;
  }

  const uploadFilename = safeUploadFilename(file.name);
  setUploadStatus(`Uploading ${uploadFilename} and preparing it for visual Q&A…`);
  elements.uploadInput.disabled = true;

  try {
    const response = await fetchJson(`/api/v1/videos-for-search/${encodeURIComponent(uploadFilename)}`, {
      method: 'PUT',
      headers: { 'Content-Type': file.type || 'video/mp4' },
      body: file,
    });
    setUploadStatus('Video is ready. Selecting it for your first question.');
    await loadVideos({ preserveSelection: false });
    const expectedName = filenameWithoutExtension(uploadFilename);
    state.selectedVideo = state.videos.find((video) => video.sensorId === response.sensor_id)
      || state.videos.find((video) => video.name === expectedName)
      || { name: filenameWithoutExtension(response.filename || uploadFilename), sensorId: response.sensor_id };
    renderSelectedVideo();
    renderVideos();
    setAdvisorStatus(`Video context set to ${state.selectedVideo.name}. Choose a prompt or write a question.`);
  } catch (error) {
    setUploadStatus(`Upload failed: ${error.message}`, true);
  } finally {
    elements.uploadInput.disabled = false;
    elements.uploadInput.value = '';
  }
}

elements.chatForm.addEventListener('submit', (event) => {
  event.preventDefault();
  askAdvisor(elements.chatInput.value);
});

elements.chatInput.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    askAdvisor(elements.chatInput.value);
  }
});

elements.promptChips.forEach((button) => {
  button.addEventListener('click', () => askAdvisor(button.dataset.prompt || ''));
});

elements.uploadInput.addEventListener('change', () => uploadVideo(elements.uploadInput.files?.[0]));

renderSelectedVideo();
loadVideos();

document.addEventListener('DOMContentLoaded', () => {
    const input = document.getElementById('chat-input');
    const history = document.getElementById('chat-history');
    const sendBtn = document.getElementById('send-btn');

    // Builds a message element without ever parsing untrusted text as HTML.
    // Preserves deliberate line breaks by inserting <br> elements between
    // text nodes rather than injecting markup via innerHTML.
    function createMessageElement(className, prefix, text, id) {
        const el = document.createElement('div');
        el.className = className;
        if (id) el.id = id;

        if (prefix) {
            el.appendChild(document.createTextNode(prefix));
        }

        const lines = String(text).split('\n');
        lines.forEach((line, index) => {
            if (prefix && index === 0) {
                // Keep prefix and first line on the same visual line.
                el.appendChild(document.createTextNode(line ? ` ${line}` : ''));
            } else {
                if (index > 0) el.appendChild(document.createElement('br'));
                el.appendChild(document.createTextNode(line));
            }
        });

        return el;
    }

    function appendMessage(className, prefix, text, id) {
        const el = createMessageElement(className, prefix, text, id);
        history.appendChild(el);
        history.scrollTop = history.scrollHeight;
        return el;
    }

    function removeLoadingIndicator() {
        const loadingEl = document.getElementById('loading');
        if (loadingEl) loadingEl.remove();
    }

    async function sha256hex(text) {
        const buf = await crypto.subtle.digest(
            'SHA-256', new TextEncoder().encode(text));
        return Array.from(new Uint8Array(buf))
            .map((b) => b.toString(16).padStart(2, '0'))
            .join('');
    }

    function paintEvidence(ev) {
        const box = document.getElementById('evidence-preview');
        if (!box) return;
        if (!ev) {
            box.textContent = 'No usable tab (chrome/brave pages are skipped).';
            return;
        }
        const clip = ev.selected
            ? ev.selected.slice(0, 400) + (ev.selected.length > 400 ? '...' : '')
            : '';
        const lines = [
            ev.title || '(no title)',
            ev.url || '(no url)',
            ev.selected
                ? ('selected ' + ev.selected.length + ' chars sha256 ' +
                   (ev.sha256 ? ev.sha256.slice(0, 12) : '') +
                   (ev.truncated ? ' truncated' : ''))
                : 'No selected text — Remember saves title+URL only.'
        ];
        if (clip) lines.push(clip);
        box.textContent = lines.join('\n');
    }

    async function collectEvidence() {
        try {
            const [tab] = await chrome.tabs.query({
                active: true,
                currentWindow: true
            });
            if (!tab || !tab.id || !tab.url ||
                tab.url.startsWith('chrome') || tab.url.startsWith('brave') ||
                tab.url.startsWith('edge') || tab.url.startsWith('about:')) {
                paintEvidence(null);
                return null;
            }
            let selected = '';
            try {
                const injected = await chrome.scripting.executeScript({
                    target: { tabId: tab.id },
                    world: 'MAIN',
                    func: () => {
                        const sel = window.getSelection && window.getSelection();
                        return sel ? String(sel.toString()) : '';
                    }
                });
                if (injected && injected[0] && typeof injected[0].result === 'string') {
                    selected = injected[0].result;
                }
            } catch (e) {
                console.log('Could not read selection:', e);
            }
            const MAX = 8192;
            const truncated = selected.length > MAX;
            if (truncated) selected = selected.slice(0, MAX);
            const ev = {
                title: tab.title || 'untitled',
                url: tab.url,
                selected: selected,
                truncated: truncated
            };
            if (selected) ev.sha256 = await sha256hex(selected);
            paintEvidence(ev);
            return ev;
        } catch (e) {
            console.log('Could not read tab:', e);
            paintEvidence(null);
            return null;
        }
    }

    collectEvidence();

    async function sendMessage() {
        const text = input.value.trim();
        if (!text) return;

        // Append User Message
        appendMessage('user-msg', '[USER]', text);
        input.value = '';

        const evidence = await collectEvidence();
        const body = { message: text };
        if (evidence) body.browser_evidence = evidence;

        appendMessage('sys-msg', '[SYS]', 'Asking GodBrain', 'loading');

        let response;
        try {
            response = await fetch('http://127.0.0.1:8083/api/chat', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });
        } catch (err) {
            // Network-level failure: the request never reached (or returned from) the server.
            removeLoadingIndicator();
            appendMessage('err-msg', '[ERR]', 'Node Offline. Is the GodBrain C++ Kernel (godbrain_core/cpp_kernel) running?');
            return;
        }

        removeLoadingIndicator();

        if (!response.ok) {
            appendMessage('err-msg', '[ERR]', `API returned ${response.status} ${response.statusText}`.trim());
            return;
        }

        // HTTP 200 does not guarantee a well-formed JSON body or the expected
        // shape, so parse defensively and report the real cause instead of
        // claiming the node is offline.
        let data;
        try {
            data = await response.json();
        } catch (parseErr) {
            appendMessage('err-msg', '[ERR]', 'Server returned invalid JSON.');
            return;
        }

        if (!data || typeof data.response !== 'string') {
            appendMessage('err-msg', '[ERR]', 'Server response missing expected "response" field.');
            return;
        }

        appendMessage('sys-msg', '[GODBRAIN]', data.response);
    }

    sendBtn.addEventListener('click', sendMessage);
    input.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') sendMessage();
    });

    const tokenInput = document.getElementById('token-input');
    if (tokenInput && chrome.storage && chrome.storage.local) {
        chrome.storage.local.get(['godbrain_api_token'], stored => {
            if (stored && stored.godbrain_api_token) {
                tokenInput.value = stored.godbrain_api_token;
            }
        });
        tokenInput.addEventListener('change', () => {
            chrome.storage.local.set({ godbrain_api_token: tokenInput.value.trim() });
        });
    }

    const rememberBtn = document.getElementById('remember-page-btn');
    if (rememberBtn) {
        rememberBtn.addEventListener('click', async () => {
            try {
                const evidence = await collectEvidence();
                if (!evidence || !evidence.url) {
                    appendMessage('err-msg', '[ERR]', 'No active page.');
                    return;
                }
                const headers = { 'Content-Type': 'application/json' };
                const token = tokenInput ? tokenInput.value.trim() : '';
                if (token) headers['Authorization'] = 'Bearer ' + token;
                const response = await fetch('http://127.0.0.1:8083/api/remember', {
                    method: 'POST',
                    headers: headers,
                    body: JSON.stringify({
                        title: evidence.title,
                        url: evidence.url,
                        selected: evidence.selected || '',
                        sha256: evidence.sha256 || '',
                        sector: 'web'
                    })
                });
                const data = await response.json().catch(() => ({}));
                if (!response.ok) {
                    appendMessage('err-msg', '[ERR]', data.error || ('HTTP ' + response.status));
                    return;
                }
                const kind = evidence.selected ? 'evidence' : 'tab metadata';
                const hash = data.keccak ? (' keccak ' + String(data.keccak).slice(0, 12)) : '';
                appendMessage(
                    'sys-msg',
                    '[SYS]',
                    'Remembered ' + kind + ' as candidate ' +
                        (data.stable_id || '') + hash);
            } catch (err) {
                appendMessage('err-msg', '[ERR]', 'Kernel offline or remember failed.');
            }
        });
    }
});

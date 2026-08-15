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

    async function sendMessage() {
        const text = input.value.trim();
        if (!text) return;

        // Append User Message
        appendMessage('user-msg', '[USER]', text);
        input.value = '';

        let pageHint = "";
        try {
            const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
            if (tab && tab.title && tab.url && !tab.url.startsWith("chrome") && !tab.url.startsWith("brave")) {
                pageHint = "Active tab: " + tab.title + " <" + tab.url + ">\n\n";
            }
        } catch (e) {
            console.log("Could not read tab:", e);
        }
        const fullQuery = pageHint + text;

        appendMessage('sys-msg', '[SYS]', 'Transmitting to Colibri...', 'loading');

        let response;
        try {
            response = await fetch('http://127.0.0.1:8083/api/chat', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ message: fullQuery })
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

    const rememberBtn = document.getElementById('remember-page-btn');
    if (rememberBtn) {
        rememberBtn.addEventListener('click', async () => {
            try {
                const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
                if (!tab || !tab.url) {
                    appendMessage('err-msg', '[ERR]', 'No active page.');
                    return;
                }
                const response = await fetch('http://127.0.0.1:8083/api/remember', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        title: tab.title || 'untitled',
                        url: tab.url,
                        text: 'Saved from Brave uplink.',
                        sector: 'web'
                    })
                });
                const data = await response.json().catch(() => ({}));
                if (!response.ok) {
                    appendMessage('err-msg', '[ERR]', data.error || ('HTTP ' + response.status));
                    return;
                }
                appendMessage('sys-msg', '[SYS]', 'Remembered as candidate ' + (data.stable_id || ''));
            } catch (err) {
                appendMessage('err-msg', '[ERR]', 'Kernel offline or remember failed.');
            }
        });
    }
});

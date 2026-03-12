/**
 * InspectorChat — SSE LiveView hook for real-time AG-UI event streaming.
 *
 * Opens EventSource to AG-UI SSE endpoint. Provides:
 * - Streaming typewriter text effect
 * - Expandable tool call cards
 * - Exponential backoff reconnection
 * - 200 message buffer cap
 * - Heartbeat pulse indicator
 */

const InspectorChat = {
  mounted() {
    this.messages = [];
    this.eventSource = null;
    this.reconnectDelay = 2000;
    this.maxReconnectDelay = 16000;
    this.maxMessages = 200;
    this.agentId = this.el.dataset.agentId || null;
    this.connected = false;
    this.heartbeatEl = null;
    this.textBuffer = {};

    // Create heartbeat indicator
    this._createHeartbeat();

    // Start SSE connection
    if (this.agentId) {
      this._connect();
    }

    // Listen for agent selection changes
    this.handleEvent("inspector:set-agent", ({ agent_id }) => {
      this.agentId = agent_id;
      this._disconnect();
      if (agent_id) this._connect();
    });

    // Listen for scope changes
    this.handleEvent("inspector:set-scope", ({ scope }) => {
      this.el.dataset.scope = scope;
    });
  },

  destroyed() {
    this._disconnect();
  },

  _connect() {
    if (this.eventSource) this._disconnect();

    const baseUrl = window.location.origin;
    const url = this.agentId
      ? `${baseUrl}/api/v2/ag-ui/events/${this.agentId}`
      : `${baseUrl}/api/v2/ag-ui/events`;

    try {
      this.eventSource = new EventSource(url);

      this.eventSource.onopen = () => {
        this.connected = true;
        this.reconnectDelay = 2000; // Reset backoff
        this._updateHeartbeat(true);
      };

      this.eventSource.onmessage = (event) => {
        this._handleEvent(event);
        this._pulseHeartbeat();
      };

      this.eventSource.onerror = () => {
        this.connected = false;
        this._updateHeartbeat(false);
        this._disconnect();
        this._scheduleReconnect();
      };

      // Listen for specific AG-UI event types
      const eventTypes = [
        "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END",
        "TOOL_CALL_START", "TOOL_CALL_ARGS", "TOOL_CALL_END",
        "RUN_STARTED", "RUN_FINISHED", "RUN_ERROR",
        "STATE_SNAPSHOT", "STATE_DELTA"
      ];

      eventTypes.forEach(type => {
        this.eventSource.addEventListener(type, (event) => {
          this._handleTypedEvent(type, JSON.parse(event.data));
        });
      });
    } catch (e) {
      console.warn("[InspectorChat] SSE connection failed:", e);
      this._scheduleReconnect();
    }
  },

  _disconnect() {
    if (this.eventSource) {
      this.eventSource.close();
      this.eventSource = null;
    }
    this.connected = false;
    this._updateHeartbeat(false);
  },

  _scheduleReconnect() {
    setTimeout(() => {
      if (this.agentId && !this.connected) {
        this._connect();
      }
    }, this.reconnectDelay);
    // Exponential backoff
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, this.maxReconnectDelay);
  },

  _handleEvent(event) {
    try {
      const data = JSON.parse(event.data);
      if (data.type) {
        this._handleTypedEvent(data.type, data);
      }
    } catch (e) {
      // Keepalive or non-JSON, ignore
    }
  },

  _handleTypedEvent(type, data) {
    switch (type) {
      case "TEXT_MESSAGE_START":
        this._startTextMessage(data);
        break;
      case "TEXT_MESSAGE_CONTENT":
        this._appendTextContent(data);
        break;
      case "TEXT_MESSAGE_END":
        this._endTextMessage(data);
        break;
      case "TOOL_CALL_START":
        this._addToolCall(data, "start");
        break;
      case "TOOL_CALL_ARGS":
        this._appendToolArgs(data);
        break;
      case "TOOL_CALL_END":
        this._addToolCall(data, "end");
        break;
      case "RUN_STARTED":
      case "RUN_FINISHED":
      case "RUN_ERROR":
        this._addSystemMessage(type, data);
        break;
    }
  },

  _startTextMessage(data) {
    const msgId = data.message_id || `msg-${Date.now()}`;
    this.textBuffer[msgId] = {
      id: msgId,
      role: data.role || "assistant",
      agent_id: data.agent_id,
      content: "",
      timestamp: new Date().toISOString()
    };

    // Push streaming start to LiveView
    this.pushEventTo(this.el, "chat:stream-start", { message_id: msgId, role: data.role });
  },

  _appendTextContent(data) {
    const msgId = data.message_id;
    if (msgId && this.textBuffer[msgId]) {
      this.textBuffer[msgId].content += data.content || "";
      // Typewriter effect: push incremental content
      this.pushEventTo(this.el, "chat:stream-content", {
        message_id: msgId,
        content: data.content
      });
    }
  },

  _endTextMessage(data) {
    const msgId = data.message_id;
    if (msgId && this.textBuffer[msgId]) {
      const msg = this.textBuffer[msgId];
      delete this.textBuffer[msgId];
      this._addMessage(msg);
      this.pushEventTo(this.el, "chat:stream-end", { message_id: msgId });
    }
  },

  _addToolCall(data, phase) {
    this._addMessage({
      id: `tool-${data.tool_call_id || Date.now()}`,
      type: "TOOL_CALL",
      tool_name: data.tool_name || data.name,
      content: JSON.stringify(data, null, 2),
      role: "tool",
      agent_id: data.agent_id,
      phase: phase,
      timestamp: new Date().toISOString()
    });
  },

  _appendToolArgs(data) {
    // Find existing tool call and append args
    const toolId = `tool-${data.tool_call_id}`;
    const existing = this.messages.find(m => m.id === toolId);
    if (existing) {
      existing.content += data.args || "";
    }
  },

  _addSystemMessage(type, data) {
    this._addMessage({
      id: `sys-${Date.now()}`,
      type: "system",
      content: `${type}: ${data.agent_id || "unknown"}`,
      role: "system",
      agent_id: data.agent_id,
      timestamp: new Date().toISOString()
    });
  },

  _addMessage(msg) {
    this.messages.unshift(msg);
    // Buffer cap
    if (this.messages.length > this.maxMessages) {
      this.messages = this.messages.slice(0, this.maxMessages);
    }
    // Notify LiveView
    this.pushEventTo(this.el, "chat:new-message", msg);
  },

  _createHeartbeat() {
    this.heartbeatEl = document.createElement("span");
    this.heartbeatEl.className = "inline-block w-2 h-2 rounded-full bg-base-content/20 transition-colors";
    this.heartbeatEl.title = "SSE Connection: Disconnected";

    const container = this.el.querySelector("[data-heartbeat]");
    if (container) container.appendChild(this.heartbeatEl);
  },

  _updateHeartbeat(connected) {
    if (!this.heartbeatEl) return;
    if (connected) {
      this.heartbeatEl.className = "inline-block w-2 h-2 rounded-full bg-success transition-colors";
      this.heartbeatEl.title = "SSE Connection: Connected";
    } else {
      this.heartbeatEl.className = "inline-block w-2 h-2 rounded-full bg-base-content/20 transition-colors";
      this.heartbeatEl.title = "SSE Connection: Disconnected";
    }
  },

  _pulseHeartbeat() {
    if (!this.heartbeatEl) return;
    this.heartbeatEl.classList.add("animate-pulse");
    setTimeout(() => {
      if (this.heartbeatEl) this.heartbeatEl.classList.remove("animate-pulse");
    }, 500);
  }
};

export default InspectorChat;

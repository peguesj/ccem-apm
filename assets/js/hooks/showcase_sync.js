/**
 * ShowcaseSync — WebSocket client that connects to ApmV5Web.ShowcaseChannel.
 *
 * Provides real-time sync between the APM Phoenix Channel and the
 * showcase engine. Separate from ShowcaseHook (LiveView push_event)
 * to give the showcase engine a persistent bidirectional channel
 * without depending on the LiveView connection.
 *
 * Usage: Attach as a LiveView hook on a lightweight div, or call
 * ShowcaseSync.connect(socket, project, engine) directly from ShowcaseHook.
 *
 * Channel: "showcase:{project}"
 *
 * Incoming push events:
 *   "agent:update"      — %{action, agent, context}
 *   "agent:context"     — %{agent_id, label, event_type, tool, recent}
 *   "notification"      — %{title, message, type, category}
 *   "graph:diff"        — %{added, removed, updated}
 *   "apm:heartbeat"     — %{ts, active_agents, total_agents}
 *   "upm:decision_gate" — %{gate_id, question, options, status}
 *   "upm:decision_resolved" — %{gate_id, decision}
 */

export class ShowcaseSyncClient {
  constructor(socket, project, opts = {}) {
    this.socket = socket;
    this.project = project || "ccem";
    this.channel = null;
    this.engine = opts.engine || null;
    this.onAgentUpdate = opts.onAgentUpdate || null;
    this.onContext = opts.onContext || null;
    this.onNotification = opts.onNotification || null;
    this.onGraphDiff = opts.onGraphDiff || null;
    this.onHeartbeat = opts.onHeartbeat || null;
    this.onGate = opts.onGate || null;
    this.connected = false;
    this._retryTimer = null;
  }

  connect() {
    if (this.channel) {
      this.channel.leave();
      this.channel = null;
    }

    this.channel = this.socket.channel(`showcase:${this.project}`, {});

    this.channel.on("agent:update", (data) => {
      this._handleAgentUpdate(data);
    });

    this.channel.on("agent:context", (data) => {
      this._handleAgentContext(data);
    });

    this.channel.on("notification", (data) => {
      this._handleNotification(data);
    });

    this.channel.on("graph:diff", (data) => {
      this._handleGraphDiff(data);
    });

    this.channel.on("apm:heartbeat", (data) => {
      this._handleHeartbeat(data);
    });

    this.channel.on("upm:decision_gate", (data) => {
      this._handleDecisionGate(data);
    });

    this.channel.on("upm:decision_resolved", (data) => {
      this._handleDecisionResolved(data);
    });

    this.channel.on("snapshot", (data) => {
      this._handleSnapshot(data);
    });

    this.channel.join()
      .receive("ok", (resp) => {
        this.connected = true;
        console.debug(`[ShowcaseSync] Connected to showcase:${this.project}`, resp);

        // Bootstrap the engine with initial snapshot if provided
        if (resp.snapshot && this.engine) {
          this.engine.updateAgentState?.(resp.snapshot.agents || []);
        }
      })
      .receive("error", (resp) => {
        console.warn("[ShowcaseSync] Channel join error:", resp);
        this._scheduleRetry();
      })
      .receive("timeout", () => {
        console.warn("[ShowcaseSync] Channel join timeout");
        this._scheduleRetry();
      });

    return this;
  }

  disconnect() {
    if (this._retryTimer) {
      clearTimeout(this._retryTimer);
      this._retryTimer = null;
    }

    if (this.channel) {
      this.channel.leave();
      this.channel = null;
    }

    this.connected = false;
  }

  setEngine(engine) {
    this.engine = engine;
    return this;
  }

  requestSnapshot() {
    if (this.channel) {
      this.channel.push("get_snapshot", {});
    }
  }

  getAgentContext(agentId, callback) {
    if (this.channel) {
      this.channel.push("get_agent_context", { agent_id: agentId })
        .receive("ok", callback)
        .receive("error", (err) => console.warn("[ShowcaseSync] getAgentContext error:", err));
    }
  }

  // -- Private ----------------------------------------------------------------

  _handleAgentUpdate(data) {
    if (this.engine) this.engine.updateAgentState?.([data.agent].filter(Boolean));
    if (this.onAgentUpdate) this.onAgentUpdate(data);

    // If agent context is present, propagate that too
    if (data.context && this.engine) {
      this.engine.setAgentContext?.(data.agent?.id, data.context);
    }
  }

  _handleAgentContext(data) {
    if (this.engine) {
      this.engine.setAgentContext?.(data.agent_id, data);
    }
    if (this.onContext) this.onContext(data);
  }

  _handleNotification(data) {
    // Inject as a toast if engine supports it
    if (this.engine) {
      this.engine.showNotification?.(data);
    }
    if (this.onNotification) this.onNotification(data);
  }

  _handleGraphDiff(data) {
    if (this.engine) {
      if (data.added?.length) this.engine.addGraphNodes?.(data.added);
      if (data.updated?.length) this.engine.updateGraphNodes?.(data.updated);
      if (data.removed?.length) this.engine.removeGraphNodes?.(data.removed);
    }
    if (this.onGraphDiff) this.onGraphDiff(data);
  }

  _handleHeartbeat(data) {
    if (this.engine) {
      this.engine.updateApmState?.({
        connected: true,
        apmConn: "live",
        active_agents: data.active_agents,
        total_agents: data.total_agents,
        ts: data.ts
      });
    }
    if (this.onHeartbeat) this.onHeartbeat(data);
  }

  _handleDecisionGate(data) {
    console.info("[ShowcaseSync] UPM Decision Gate:", data);
    if (this.engine) this.engine.showDecisionGate?.(data);
    if (this.onGate) this.onGate(data);
  }

  _handleDecisionResolved(data) {
    console.info("[ShowcaseSync] UPM Decision Resolved:", data);
    if (this.engine) this.engine.resolveDecisionGate?.(data);
  }

  _handleSnapshot(data) {
    if (this.engine && data.agents) {
      this.engine.updateAgentState?.(data.agents);
    }

    if (this.engine && data.contexts) {
      Object.entries(data.contexts).forEach(([agentId, ctx]) => {
        this.engine.setAgentContext?.(agentId, ctx);
      });
    }
  }

  _scheduleRetry() {
    if (this._retryTimer) return;

    this._retryTimer = setTimeout(() => {
      this._retryTimer = null;
      console.debug("[ShowcaseSync] Retrying channel connection...");
      this.connect();
    }, 5_000);
  }
}

/**
 * ShowcaseSyncHook — lightweight LiveView hook that bootstraps ShowcaseSyncClient.
 *
 * Mount on any element that has the Phoenix socket available via liveSocket.
 * Exposes the client as window.__showcaseSync for integration with ShowcaseHook.
 */
export const ShowcaseSyncHook = {
  mounted() {
    const project = this.el.dataset.project || "ccem";

    // Wait for the Phoenix socket to be available
    const tryConnect = () => {
      if (window.liveSocket && window.liveSocket.socket) {
        this._client = new ShowcaseSyncClient(window.liveSocket.socket, project);
        this._client.connect();
        window.__showcaseSync = this._client;
      } else {
        setTimeout(tryConnect, 500);
      }
    };

    tryConnect();
  },

  updated() {
    const newProject = this.el.dataset.project;
    if (this._client && newProject && newProject !== this._client.project) {
      this._client.disconnect();
      this._client.project = newProject;
      this._client.connect();
    }
  },

  destroyed() {
    if (this._client) {
      this._client.disconnect();
      this._client = null;
    }
    if (window.__showcaseSync) {
      window.__showcaseSync = null;
    }
  }
};

export default ShowcaseSyncHook;

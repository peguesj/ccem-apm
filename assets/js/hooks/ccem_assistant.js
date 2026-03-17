/**
 * CcemAssistant — JS hook for the CCEM Management callout chat.
 *
 * Handles:
 * - `ccem:style_update` events from LiveView → applies CSS to targeted elements
 * - `ccem:stream_token` events → appends streamed text to the last assistant message
 * - `ccem:wizard_trigger` events → re-triggers the getting-started wizard
 * - Scroll-to-bottom for the chat messages container
 */
const CcemAssistant = {
  mounted() {
    this._styleOverrides = {};
    this._streamBuffer = "";

    // ccem:style_update — apply CSS property to selector
    this.handleEvent("ccem:style_update", ({ selector, property, value, label }) => {
      if (property === "reset") {
        // Reset all inline styles on matching elements
        document.querySelectorAll(selector).forEach(el => {
          el.style.cssText = "";
        });
        this._styleOverrides = {};
        return;
      }

      const targets = document.querySelectorAll(selector);
      if (targets.length === 0) {
        console.warn("[CcemAssistant] No elements found for selector:", selector);
        return;
      }

      // Apply the style
      const cssProp = property.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      targets.forEach(el => {
        el.style[cssProp] = value;
        // Also add a brief highlight flash
        el.style.transition = "all 0.3s ease";
      });

      // Track override
      if (!this._styleOverrides[selector]) this._styleOverrides[selector] = {};
      this._styleOverrides[selector][property] = value;

      console.log(`[CcemAssistant] Style update: ${selector} { ${property}: ${value} } (${label})`);
    });

    // ccem:stream_token — append token to the last assistant message
    this.handleEvent("ccem:stream_token", ({ content }) => {
      this._streamBuffer += content;
      const messages = document.getElementById("ccem-chat-messages");
      if (!messages) return;
      const lastMsg = messages.querySelector(".ccem-streaming");
      if (lastMsg) {
        lastMsg.textContent = this._streamBuffer;
      }
    });

    // ccem:wizard_trigger — re-show the getting-started wizard
    this.handleEvent("ccem:wizard_trigger", ({ page }) => {
      // Clear the localStorage dismissal flag for this page
      const key = `ccem_wizard_${page}_dismissed`;
      localStorage.removeItem(key);
      // Re-mount wizard: find the wizard element and dispatch a show event
      const wizardEl = document.querySelector(`[id^="ccem-wizard-"]`);
      if (wizardEl) {
        wizardEl.dispatchEvent(new CustomEvent("ccem:wizard_show", { bubbles: true }));
      }
      // Fallback: reload to show wizard again
      if (!wizardEl) window.location.reload();
    });
  },

  updated() {
    // Scroll chat messages to bottom on update
    const messages = document.getElementById("ccem-chat-messages");
    if (messages) {
      messages.scrollTop = messages.scrollHeight;
    }

    // Reapply any style overrides after LiveView re-render
    for (const [selector, styles] of Object.entries(this._styleOverrides)) {
      const cssProp = (prop) => prop.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      document.querySelectorAll(selector).forEach(el => {
        for (const [property, value] of Object.entries(styles)) {
          el.style[cssProp(property)] = value;
        }
      });
    }
  }
};

export default CcemAssistant;

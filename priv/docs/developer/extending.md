# Extending CCEM APM

This guide explains how to add new features to CCEM APM v4.

## Adding a New GenServer/Store

GenServers manage state and broadcast events. Follow this pattern to add a new store:

### Step 1: Create the Module

Create `lib/apm_v4/my_feature_store.ex`:

```elixir
defmodule ApmV4.MyFeatureStore do
  use GenServer
  require Logger

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_data(key) do
    GenServer.call(__MODULE__, {:get_data, key})
  end

  def set_data(key, value) do
    GenServer.cast(__MODULE__, {:set_data, key, value})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("#{__MODULE__} started")

    # Initialize ETS table if needed
    :ets.new(:my_feature_table, [:set, :public, :named_table])

    {:ok, %{data: %{}}}
  end

  @impl true
  def handle_call({:get_data, key}, _from, state) do
    value = Map.get(state.data, key)
    {:reply, value, state}
  end

  @impl true
  def handle_cast({:set_data, key, value}, state) do
    new_state = %{state | data: Map.put(state.data, key, value)}

    # Broadcast event
    Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:my_feature", {:data_updated, key, value})

    {:noreply, new_state}
  end
end
```

### Step 2: Add to Supervision Tree

Edit `lib/apm_v4/application.ex` and add your module to the `children` list:

```elixir
children = [
  # ... existing children ...
  ApmV4.MyFeatureStore,
  # Start to serve requests, typically the last entry
  ApmV4Web.Endpoint
]
```

### Step 3: Subscribe to Events (if needed)

If your store needs to listen to other events:

```elixir
@impl true
def init(_opts) do
  Logger.info("#{__MODULE__} started")

  # Subscribe to other topics
  Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:agents")
  Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:config")

  {:ok, %{data: %{}}}
end

@impl true
def handle_info({:agent_registered, agent}, state) do
  Logger.debug("Agent registered: #{agent.name}")
  {:noreply, state}
end

def handle_info({:config_reloaded, _config}, state) do
  {:noreply, reload_state(state)}
end
```

## Adding a New API Endpoint

### Step 1: Create Controller

Create `lib/apm_v4_web/controllers/my_feature_controller.ex`:

```elixir
defmodule ApmV4Web.MyFeatureController do
  use ApmV4Web, :controller

  def get_data(conn, %{"key" => key}) do
    data = ApmV4.MyFeatureStore.get_data(key)

    json(conn, %{
      data: data,
      timestamp: DateTime.utc_now()
    })
  end

  def set_data(conn, %{"key" => key, "value" => value}) do
    ApmV4.MyFeatureStore.set_data(key, value)

    json(conn, %{status: "ok"})
  end
end
```

### Step 2: Add Routes

Edit `lib/apm_v4_web/router.ex`:

```elixir
scope "/api", ApmV4Web do
  pipe_through :api

  # ... existing routes ...

  get "/my_feature/:key", MyFeatureController, :get_data
  post "/my_feature", MyFeatureController, :set_data
end
```

### Step 3: Test the Endpoint

```bash
curl http://localhost:3031/api/my_feature/test_key
curl -X POST http://localhost:3031/api/my_feature \
  -H "Content-Type: application/json" \
  -d '{"key": "test", "value": "data"}'
```

## Adding a New LiveView Page

### Step 1: Create LiveView Module

Create `lib/apm_v4_web/live/my_feature_live.ex`:

```elixir
defmodule ApmV4Web.MyFeatureLive do
  use ApmV4Web, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container">
      <h1>My Feature</h1>
      <p><%= @feature_data %></p>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:my_feature")
    end

    feature_data = fetch_feature_data()

    {:ok, assign(socket, feature_data: feature_data)}
  end

  @impl true
  def handle_info({:data_updated, _key, _value}, socket) do
    feature_data = fetch_feature_data()
    {:noreply, assign(socket, feature_data: feature_data)}
  end

  defp fetch_feature_data do
    ApmV4.MyFeatureStore.get_data("all")
  end
end
```

### Step 2: Add Route

Edit `lib/apm_v4_web/router.ex`:

```elixir
scope "/", ApmV4Web do
  pipe_through :browser

  # ... existing routes ...

  live "/my-feature", MyFeatureLive
end
```

### Step 3: Add Navigation Link

Add a `nav_item` entry in your LiveView's render function sidebar:

```heex
<.nav_item icon="hero-star" label="My Feature" active={true} href="/my-feature" />
```

## Adding PubSub Topics

Create new PubSub topic for custom events:

```elixir
# Broadcast event
Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:my_feature", {:custom_event, data})

# Subscribe in LiveView
Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:my_feature")

# Handle in LiveView or GenServer
def handle_info({:custom_event, data}, socket) do
  {:noreply, assign(socket, :data, data)}
end
```

## Adding UI Components

Use daisyUI components from Tailwind CSS:

```heex
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title"><%= @title %></h2>
    <p><%= @content %></p>
    <div class="card-actions justify-end">
      <button class="btn btn-primary">Action</button>
    </div>
  </div>
</div>
```

Reference daisyUI documentation: https://daisyui.com/

## Adding JavaScript Hooks

Create JS hooks for client-side interactivity:

### Hook Definition

Create `assets/js/hooks/my_hook.js`:

```javascript
export const MyHook = {
  mounted() {
    console.log("MyHook mounted")
    this.setupInteractions()
  },

  setupInteractions() {
    this.el.addEventListener('click', () => {
      this.pushEvent('my_event', { data: 'value' })
    })
  }
}
```

### Register Hook

In `assets/js/app.js`:

```javascript
import { MyHook } from './hooks/my_hook'

let liveSocket = new LiveSocket('/live', Socket, {
  hooks: {
    MyHook
  }
})
```

### Use in Template

```heex
<div phx-hook="MyHook" id="my-element">
  Click me
</div>
```

## Adding Configuration Options

Add new config fields to `apm_config.json`:

```json
{
  "project_name": "ccem",
  "my_feature": {
    "enabled": true,
    "setting1": "value1"
  }
}
```

Access in code:

```elixir
config = ApmV4.ConfigLoader.get_config()
my_feature_config = config["my_feature"]
```

## Testing New Features

### Unit Test

Create `test/apm_v4/my_feature_store_test.exs`:

```elixir
defmodule ApmV4.MyFeatureStoreTest do
  use ExUnit.Case

  test "get_data returns value" do
    ApmV4.MyFeatureStore.set_data("key", "value")
    assert ApmV4.MyFeatureStore.get_data("key") == "value"
  end
end
```

### Integration Test

Create `test/apm_v4_web/controllers/my_feature_controller_test.exs`:

```elixir
defmodule ApmV4Web.MyFeatureControllerTest do
  use ApmV4Web.ConnCase

  test "GET /api/my_feature/:key", %{conn: conn} do
    conn = get(conn, ~p"/api/my_feature/test")
    assert json_response(conn, 200)["data"]
  end
end
```

### LiveView Test

Create `test/apm_v4_web/live/my_feature_live_test.exs`:

```elixir
defmodule ApmV4Web.MyFeatureLiveTest do
  use ApmV4Web.ConnCase

  test "renders feature data", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/my-feature")

    assert html =~ "My Feature"
  end
end
```

## Documentation

Add documentation file in `priv/docs/`:

1. **User docs** in `priv/docs/user/feature_name.md`
2. **Developer docs** in `priv/docs/developer/feature_name.md`
3. **Update index.md** with link to new docs

## Common Patterns

### Broadcasting on State Change

```elixir
def set_value(value) do
  GenServer.cast(__MODULE__, {:set_value, value})
end

def handle_cast({:set_value, value}, state) do
  new_state = %{state | value: value}
  Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:my_feature", {:value_changed, value})
  {:noreply, new_state}
end
```

### Handling Config Reload

```elixir
def handle_info({:config_reloaded, config}, state) do
  # Re-initialize with new config
  new_state = init_with_config(config)
  {:noreply, new_state}
end
```

### Error Handling

```elixir
def set_value(value) do
  case validate_value(value) do
    :ok ->
      ApmV4.MyFeatureStore.set_value(value)
      {:ok, "Value set"}

    {:error, reason} ->
      Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:notifications", {
        :notification_added,
        %{level: "error", message: reason}
      })
      {:error, reason}
  end
end
```

## Next Steps

1. Review [Architecture](architecture.md) for system design
2. Check [API Reference](api-reference.md) for existing endpoints
3. Study [PubSub Events](pubsub-events.md) for event patterns
4. Look at existing code in `lib/apm_v4/` for examples

## Support

For questions about extending CCEM APM:

1. Check existing similar features
2. Review test examples
3. Consult [Architecture](architecture.md)
4. Ask in project discussions

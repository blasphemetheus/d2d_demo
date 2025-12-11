defmodule D2dDemoWeb.DashboardLive do
  use D2dDemoWeb, :live_view
  alias D2dDemo.LoRa
  alias D2dDemo.Network.{WiFi, Bluetooth, TestRunner}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(D2dDemo.PubSub, "lora:rx")
      Phoenix.PubSub.subscribe(D2dDemo.PubSub, "lora:tx")
      Phoenix.PubSub.subscribe(D2dDemo.PubSub, "network:wifi:status")
      Phoenix.PubSub.subscribe(D2dDemo.PubSub, "network:bluetooth:status")
      Phoenix.PubSub.subscribe(D2dDemo.PubSub, "network:test")
    end

    {:ok,
     assign(socket,
       # Tab state
       active_tab: :lora,
       # LoRa state
       lora_connected: LoRa.connected?(),
       lora_port: "/dev/ttyACM0",
       radio_settings: nil,
       tx_message: "",
       rx_messages: [],
       frequency: "915000000",
       spreading_factor: "7",
       bandwidth: "125",
       power: "14",
       # WiFi state
       wifi_connected: WiFi.connected?(),
       wifi_interface: WiFi.get_interface(),
       wifi_rssi: nil,
       wifi_test_running: false,
       wifi_test_results: [],
       # Bluetooth state
       bt_connected: Bluetooth.connected?(),
       bt_peer_mac: Bluetooth.get_peer_mac(),
       bt_test_running: false,
       bt_test_results: [],
       # Shared
       test_label: "",
       command_log: []
     )}
  end

  # ============================================
  # Tab switching
  # ============================================

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end

  # ============================================
  # LoRa Events
  # ============================================

  @impl true
  def handle_event("connect_lora", _params, socket) do
    case LoRa.connect(socket.assigns.lora_port) do
      :ok ->
        LoRa.pause_mac()
        {:ok, settings} = LoRa.get_radio_settings()

        {:noreply,
         socket
         |> assign(lora_connected: true, radio_settings: settings)
         |> add_log("LoRa: Connected to #{socket.assigns.lora_port}")}

      {:error, reason} ->
        {:noreply, add_log(socket, "LoRa: Connection failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("disconnect_lora", _params, socket) do
    LoRa.disconnect()
    {:noreply,
     socket
     |> assign(lora_connected: false, radio_settings: nil)
     |> add_log("LoRa: Disconnected")}
  end

  @impl true
  def handle_event("update_port", %{"port" => port}, socket) do
    {:noreply, assign(socket, lora_port: port)}
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    case LoRa.transmit(message) do
      {:ok, _} ->
        {:noreply, socket |> assign(tx_message: "") |> add_log("LoRa TX: #{message}")}
      {:error, reason} ->
        {:noreply, add_log(socket, "LoRa TX Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("update_tx_message", %{"message" => message}, socket) do
    {:noreply, assign(socket, tx_message: message)}
  end

  @impl true
  def handle_event("start_rx", _params, socket) do
    case LoRa.receive_mode(0) do
      {:ok, _} -> {:noreply, add_log(socket, "LoRa: Listening for messages...")}
      {:error, reason} -> {:noreply, add_log(socket, "LoRa RX Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("set_frequency", %{"frequency" => freq}, socket) do
    socket = assign(socket, frequency: freq)
    if socket.assigns.lora_connected do
      case LoRa.set_frequency(freq) do
        {:ok, _} -> {:noreply, add_log(socket, "LoRa: Frequency set to #{freq} Hz")}
        {:error, reason} -> {:noreply, add_log(socket, "Error: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_sf", %{"sf" => sf}, socket) do
    socket = assign(socket, spreading_factor: sf)
    if socket.assigns.lora_connected do
      case LoRa.set_spreading_factor(String.to_integer(sf)) do
        {:ok, _} -> {:noreply, add_log(socket, "LoRa: SF set to #{sf}")}
        {:error, reason} -> {:noreply, add_log(socket, "Error: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_bw", %{"bw" => bw}, socket) do
    socket = assign(socket, bandwidth: bw)
    if socket.assigns.lora_connected do
      case LoRa.set_bandwidth(String.to_integer(bw)) do
        {:ok, _} -> {:noreply, add_log(socket, "LoRa: Bandwidth set to #{bw} kHz")}
        {:error, reason} -> {:noreply, add_log(socket, "Error: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_power", %{"power" => power}, socket) do
    socket = assign(socket, power: power)
    if socket.assigns.lora_connected do
      case LoRa.set_power(String.to_integer(power)) do
        {:ok, _} -> {:noreply, add_log(socket, "LoRa: Power set to #{power} dBm")}
        {:error, reason} -> {:noreply, add_log(socket, "Error: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("send_raw_cmd", %{"cmd" => cmd}, socket) do
    case LoRa.send_command(cmd) do
      {:ok, response} -> {:noreply, add_log(socket, "> #{cmd}\n< #{response}")}
      {:error, reason} -> {:noreply, add_log(socket, "Error: #{inspect(reason)}")}
    end
  end

  # ============================================
  # WiFi Events
  # ============================================

  @impl true
  def handle_event("wifi_connect", _params, socket) do
    socket = add_log(socket, "WiFi: Connecting to ad-hoc network...")
    case WiFi.setup(socket.assigns.wifi_interface) do
      :ok ->
        # Don't fetch RSSI immediately - it may not be available yet
        {:noreply,
         socket
         |> assign(wifi_connected: true, wifi_rssi: nil)
         |> add_log("WiFi: Connected on #{socket.assigns.wifi_interface}")}
      {:error, reason} ->
        {:noreply, add_log(socket, "WiFi: Connection failed: #{String.slice(to_string(reason), 0, 100)}")}
    end
  end

  @impl true
  def handle_event("wifi_disconnect", _params, socket) do
    WiFi.teardown()
    {:noreply,
     socket
     |> assign(wifi_connected: false, wifi_rssi: nil)
     |> add_log("WiFi: Disconnected")}
  end

  @impl true
  def handle_event("update_wifi_interface", %{"interface" => iface}, socket) do
    {:noreply, assign(socket, wifi_interface: iface)}
  end

  @impl true
  def handle_event("wifi_reset", _params, socket) do
    socket = add_log(socket, "WiFi: Resetting NetworkManager...")
    WiFi.reset_network_manager()
    {:noreply,
     socket
     |> assign(wifi_connected: false, wifi_rssi: nil)
     |> add_log("WiFi: NetworkManager restored")}
  end

  @impl true
  def handle_event("wifi_ping", _params, socket) do
    socket = socket |> assign(wifi_test_running: true) |> add_log("WiFi: Running ping test...")
    peer_ip = WiFi.get_peer_ip()
    label = socket.assigns.test_label

    Task.start(fn ->
      TestRunner.run_ping(peer_ip, 10, transport: :wifi, label: label)
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("wifi_throughput", _params, socket) do
    socket = socket |> assign(wifi_test_running: true) |> add_log("WiFi: Running throughput test...")
    peer_ip = WiFi.get_peer_ip()
    label = socket.assigns.test_label

    Task.start(fn ->
      TestRunner.run_throughput(peer_ip, 10, transport: :wifi, label: label)
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_test_label", %{"label" => label}, socket) do
    {:noreply, assign(socket, test_label: label)}
  end

  # ============================================
  # Bluetooth Events
  # ============================================

  @impl true
  def handle_event("bt_connect", _params, socket) do
    socket = add_log(socket, "Bluetooth: Connecting to #{socket.assigns.bt_peer_mac}...")
    case Bluetooth.connect(socket.assigns.bt_peer_mac) do
      :ok ->
        {:noreply,
         socket
         |> assign(bt_connected: true)
         |> add_log("Bluetooth: Connected")}
      {:error, reason} ->
        {:noreply, add_log(socket, "Bluetooth: Connection failed: #{String.slice(to_string(reason), 0, 100)}")}
    end
  end

  @impl true
  def handle_event("bt_disconnect", _params, socket) do
    Bluetooth.disconnect()
    {:noreply,
     socket
     |> assign(bt_connected: false)
     |> add_log("Bluetooth: Disconnected")}
  end

  @impl true
  def handle_event("update_bt_mac", %{"mac" => mac}, socket) do
    Bluetooth.set_peer_mac(mac)
    {:noreply, assign(socket, bt_peer_mac: mac)}
  end

  @impl true
  def handle_event("bt_ping", _params, socket) do
    socket = socket |> assign(bt_test_running: true) |> add_log("Bluetooth: Running ping test...")
    peer_ip = Bluetooth.get_peer_ip()
    label = socket.assigns.test_label

    Task.start(fn ->
      TestRunner.run_ping(peer_ip, 10, transport: :bluetooth, label: label)
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("bt_throughput", _params, socket) do
    socket = socket |> assign(bt_test_running: true) |> add_log("Bluetooth: Running throughput test...")
    peer_ip = Bluetooth.get_peer_ip()
    label = socket.assigns.test_label

    Task.start(fn ->
      TestRunner.run_throughput(peer_ip, 10, transport: :bluetooth, label: label)
    end)

    {:noreply, socket}
  end

  # ============================================
  # PubSub Handlers
  # ============================================

  @impl true
  def handle_info({:lora_rx, data}, socket) do
    message = %{data: data, timestamp: DateTime.utc_now(), hex: Base.encode16(data)}
    {:noreply,
     socket
     |> update(:rx_messages, fn msgs -> [message | Enum.take(msgs, 49)] end)
     |> add_log("LoRa RX: #{data} (#{message.hex})")}
  end

  @impl true
  def handle_info(:tx_ok, socket) do
    {:noreply, add_log(socket, "LoRa: TX OK")}
  end

  @impl true
  def handle_info(:tx_error, socket) do
    {:noreply, add_log(socket, "LoRa: TX ERROR")}
  end

  @impl true
  def handle_info({:wifi_connected, status}, socket) do
    {:noreply, assign(socket, wifi_connected: status)}
  end

  @impl true
  def handle_info({:bt_connected, status}, socket) do
    {:noreply, assign(socket, bt_connected: status)}
  end

  @impl true
  def handle_info({:test_started, test_type, transport}, socket) do
    {:noreply, add_log(socket, "#{transport}: Starting #{test_type} test...")}
  end

  @impl true
  def handle_info({:test_complete, _test_type, %{transport: :wifi} = result}, socket) do
    log_msg = format_test_result(result)
    {:noreply,
     socket
     |> assign(wifi_test_running: false)
     |> update(:wifi_test_results, fn results -> [result | Enum.take(results, 19)] end)
     |> add_log("WiFi: #{log_msg}")}
  end

  @impl true
  def handle_info({:test_complete, _test_type, %{transport: :bluetooth} = result}, socket) do
    log_msg = format_test_result(result)
    {:noreply,
     socket
     |> assign(bt_test_running: false)
     |> update(:bt_test_results, fn results -> [result | Enum.take(results, 19)] end)
     |> add_log("Bluetooth: #{log_msg}")}
  end

  defp format_test_result(%{error: error} = r) do
    route_str = format_route_short(r)
    "Error: #{error}#{route_str}"
  end

  defp format_test_result(%{test_type: :ping} = r) do
    route_str = format_route_short(r)
    "Ping: #{r.rtt_avg_ms}ms avg, #{r.packet_loss_percent}% loss#{route_str}"
  end

  defp format_test_result(%{test_type: :throughput} = r) do
    route_str = format_route_short(r)
    "Throughput: #{r.bandwidth_mbps} Mbps#{route_str}"
  end

  defp format_route_short(%{route: %{interface: iface}}) when not is_nil(iface) do
    " via #{iface}"
  end

  defp format_route_short(_), do: ""

  defp add_log(socket, message) do
    entry = %{message: message, timestamp: DateTime.utc_now()}
    update(socket, :command_log, fn log -> [entry | Enum.take(log, 99)] end)
  end

  # ============================================
  # Render
  # ============================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200 p-4">
      <div class="max-w-6xl mx-auto">
        <h1 class="text-3xl font-bold mb-6">D2D Communication Demo</h1>

        <!-- Test Label -->
        <div class="flex items-center gap-4 mb-4">
          <span class="font-semibold">Test Label:</span>
          <form phx-change="update_test_label" class="flex-1 max-w-md">
            <input
              type="text"
              name="label"
              value={@test_label}
              phx-debounce="200"
              class="input input-bordered input-sm w-full"
              placeholder="e.g. 20ft_test1, indoor_close, outdoor_50m"
            />
          </form>
        </div>

        <!-- Tab Navigation -->
        <div class="tabs tabs-boxed mb-6 bg-base-100 p-2">
          <button
            class={"tab tab-lg " <> if(@active_tab == :lora, do: "tab-active", else: "")}
            phx-click="switch_tab"
            phx-value-tab="lora"
          >
            📡 LoRa
          </button>
          <button
            class={"tab tab-lg " <> if(@active_tab == :wifi, do: "tab-active", else: "")}
            phx-click="switch_tab"
            phx-value-tab="wifi"
          >
            📶 WiFi
          </button>
          <button
            class={"tab tab-lg " <> if(@active_tab == :bluetooth, do: "tab-active", else: "")}
            phx-click="switch_tab"
            phx-value-tab="bluetooth"
          >
            🔵 Bluetooth
          </button>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Left/Center: Tab Content -->
          <div class="lg:col-span-2 space-y-6">
            <%= case @active_tab do %>
              <% :lora -> %>
                <.lora_tab {assigns} />
              <% :wifi -> %>
                <.wifi_tab {assigns} />
              <% :bluetooth -> %>
                <.bluetooth_tab {assigns} />
            <% end %>
          </div>

          <!-- Right: Activity Log -->
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title">Activity Log</h2>
              <div class="bg-base-300 rounded-lg p-4 h-[500px] overflow-y-auto font-mono text-sm">
                <%= for entry <- @command_log do %>
                  <div class="mb-1">
                    <span class="text-base-content/50">
                      <%= Calendar.strftime(entry.timestamp, "%H:%M:%S") %>
                    </span>
                    <span class="whitespace-pre-wrap"><%= entry.message %></span>
                  </div>
                <% end %>
                <%= if @command_log == [] do %>
                  <div class="text-base-content/50">No activity yet...</div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ============================================
  # LoRa Tab Component
  # ============================================

  defp lora_tab(assigns) do
    ~H"""
    <!-- Connection -->
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <div class="flex items-center gap-4">
          <div class={"badge badge-lg " <> if(@lora_connected, do: "badge-success", else: "badge-error")}>
            <%= if @lora_connected, do: "Connected", else: "Disconnected" %>
          </div>
          <input
            type="text"
            value={@lora_port}
            phx-blur="update_port"
            phx-value-port={@lora_port}
            class="input input-bordered input-sm w-48"
            placeholder="/dev/ttyACM0"
          />
          <%= if @lora_connected do %>
            <button phx-click="disconnect_lora" class="btn btn-error btn-sm">Disconnect</button>
          <% else %>
            <button phx-click="connect_lora" class="btn btn-primary btn-sm">Connect</button>
          <% end %>
        </div>
      </div>
    </div>

    <!-- Radio Settings -->
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">Radio Settings</h2>
        <div class="grid grid-cols-2 gap-4">
          <div class="form-control">
            <label class="label"><span class="label-text">Frequency</span></label>
            <select class="select select-bordered" phx-change="set_frequency" name="frequency" disabled={!@lora_connected}>
              <option value="868100000" selected={@frequency == "868100000"}>868.1 MHz (EU)</option>
              <option value="915000000" selected={@frequency == "915000000"}>915.0 MHz (US)</option>
            </select>
          </div>
          <div class="form-control">
            <label class="label"><span class="label-text">Spreading Factor</span></label>
            <select class="select select-bordered" phx-change="set_sf" name="sf" disabled={!@lora_connected}>
              <%= for sf <- 7..12 do %>
                <option value={sf} selected={@spreading_factor == to_string(sf)}>SF<%= sf %></option>
              <% end %>
            </select>
          </div>
          <div class="form-control">
            <label class="label"><span class="label-text">Bandwidth</span></label>
            <select class="select select-bordered" phx-change="set_bw" name="bw" disabled={!@lora_connected}>
              <option value="125" selected={@bandwidth == "125"}>125 kHz</option>
              <option value="250" selected={@bandwidth == "250"}>250 kHz</option>
              <option value="500" selected={@bandwidth == "500"}>500 kHz</option>
            </select>
          </div>
          <div class="form-control">
            <label class="label"><span class="label-text">Power: <%= @power %> dBm</span></label>
            <input type="range" min="-3" max="14" value={@power} class="range" phx-change="set_power" name="power" disabled={!@lora_connected} />
          </div>
        </div>
      </div>
    </div>

    <!-- Transmit / Receive -->
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">Transmit / Receive</h2>
        <form phx-submit="send_message" class="flex gap-2">
          <input type="text" name="message" value={@tx_message} phx-change="update_tx_message" class="input input-bordered flex-1" placeholder="Message to send..." disabled={!@lora_connected} />
          <button type="submit" class="btn btn-primary" disabled={!@lora_connected}>Send</button>
        </form>
        <div class="flex gap-2 mt-2">
          <button phx-click="start_rx" class="btn btn-secondary" disabled={!@lora_connected}>Start Listening</button>
        </div>
      </div>
    </div>

    <!-- Received Messages -->
    <%= if @rx_messages != [] do %>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title">Received Messages</h2>
          <div class="overflow-x-auto max-h-48">
            <table class="table table-zebra table-sm">
              <thead><tr><th>Time</th><th>Data</th><th>Hex</th></tr></thead>
              <tbody>
                <%= for msg <- @rx_messages do %>
                  <tr>
                    <td><%= Calendar.strftime(msg.timestamp, "%H:%M:%S") %></td>
                    <td><%= msg.data %></td>
                    <td class="font-mono text-xs"><%= msg.hex %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # ============================================
  # WiFi Tab Component
  # ============================================

  defp wifi_tab(assigns) do
    ~H"""
    <!-- Connection -->
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">WiFi Ad-hoc Connection</h2>
        <div class="flex items-center gap-4 flex-wrap">
          <div class={"badge badge-lg " <> if(@wifi_connected, do: "badge-success", else: "badge-error")}>
            <%= if @wifi_connected, do: "Connected", else: "Disconnected" %>
          </div>
          <form phx-change="update_wifi_interface" class="contents">
            <input
              type="text"
              name="interface"
              value={@wifi_interface}
              phx-debounce="300"
              class="input input-bordered input-sm w-40"
              placeholder="wlp0s20f3"
            />
          </form>
          <%= if @wifi_connected do %>
            <button phx-click="wifi_disconnect" class="btn btn-error btn-sm">Disconnect</button>
            <%= if @wifi_rssi do %>
              <span class="text-sm">RSSI: <%= @wifi_rssi %> dBm</span>
            <% end %>
          <% else %>
            <button phx-click="wifi_connect" class="btn btn-primary btn-sm">Connect</button>
            <button phx-click="wifi_reset" class="btn btn-warning btn-sm">Reset NetworkManager</button>
          <% end %>
        </div>
        <div class="text-sm text-base-content/70 mt-2">
          Network: PiAdhoc | Your IP: 192.168.12.2 | Peer: 192.168.12.1
        </div>
      </div>
    </div>

    <!-- Tests -->
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">Network Tests</h2>
        <div class="flex gap-4">
          <button phx-click="wifi_ping" class="btn btn-primary" disabled={!@wifi_connected or @wifi_test_running}>
            <%= if @wifi_test_running, do: "Running...", else: "Run Ping Test" %>
          </button>
          <button phx-click="wifi_throughput" class="btn btn-secondary" disabled={!@wifi_connected or @wifi_test_running}>
            Run Throughput Test
          </button>
        </div>
        <%= if @wifi_test_running do %>
          <progress class="progress progress-primary w-full mt-4"></progress>
        <% end %>
      </div>
    </div>

    <!-- Results -->
    <.test_results_table results={@wifi_test_results} title="WiFi Test Results" />
    """
  end

  # ============================================
  # Bluetooth Tab Component
  # ============================================

  defp bluetooth_tab(assigns) do
    ~H"""
    <!-- Connection -->
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">Bluetooth PAN Connection</h2>
        <div class="flex items-center gap-4 flex-wrap">
          <div class={"badge badge-lg " <> if(@bt_connected, do: "badge-success", else: "badge-error")}>
            <%= if @bt_connected, do: "Connected", else: "Disconnected" %>
          </div>
          <input
            type="text"
            value={@bt_peer_mac}
            phx-blur="update_bt_mac"
            phx-value-mac={@bt_peer_mac}
            class="input input-bordered input-sm w-48 font-mono"
            placeholder="B8:27:EB:D6:9C:95"
          />
          <%= if @bt_connected do %>
            <button phx-click="bt_disconnect" class="btn btn-error btn-sm">Disconnect</button>
          <% else %>
            <button phx-click="bt_connect" class="btn btn-primary btn-sm">Connect</button>
          <% end %>
        </div>
        <div class="text-sm text-base-content/70 mt-2">
          Your IP: 192.168.44.2 | Peer: 192.168.44.1
        </div>
      </div>
    </div>

    <!-- Tests -->
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">Network Tests</h2>
        <div class="flex gap-4">
          <button phx-click="bt_ping" class="btn btn-primary" disabled={!@bt_connected or @bt_test_running}>
            <%= if @bt_test_running, do: "Running...", else: "Run Ping Test" %>
          </button>
          <button phx-click="bt_throughput" class="btn btn-secondary" disabled={!@bt_connected or @bt_test_running}>
            Run Throughput Test
          </button>
        </div>
        <%= if @bt_test_running do %>
          <progress class="progress progress-primary w-full mt-4"></progress>
        <% end %>
      </div>
    </div>

    <!-- Results -->
    <.test_results_table results={@bt_test_results} title="Bluetooth Test Results" />
    """
  end

  # ============================================
  # Shared Components
  # ============================================

  defp test_results_table(assigns) do
    ~H"""
    <%= if @results != [] do %>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title"><%= @title %></h2>
          <div class="overflow-x-auto max-h-64">
            <table class="table table-zebra table-sm">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Label</th>
                  <th>Test</th>
                  <th>Route</th>
                  <th>Latency (ms)</th>
                  <th>Throughput (Mbps)</th>
                  <th>Loss %</th>
                </tr>
              </thead>
              <tbody>
                <%= for result <- @results do %>
                  <tr>
                    <td><%= Calendar.strftime(result.timestamp, "%H:%M:%S") %></td>
                    <td class="font-mono text-xs"><%= Map.get(result, :label, "") %></td>
                    <td><%= result.test_type %></td>
                    <td class="font-mono text-xs"><%= format_route(result) %></td>
                    <td><%= Map.get(result, :rtt_avg_ms) || "-" %></td>
                    <td><%= Map.get(result, :bandwidth_mbps) || "-" %></td>
                    <td><%= if Map.get(result, :packet_loss_percent), do: "#{result.packet_loss_percent}%", else: "-" %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp format_route(%{route: %{interface: iface, source_ip: src}}) when not is_nil(iface) do
    "#{iface} (#{src})"
  end

  defp format_route(%{route: %{error: error}}) do
    "Error: #{error}"
  end

  defp format_route(_), do: "-"
end

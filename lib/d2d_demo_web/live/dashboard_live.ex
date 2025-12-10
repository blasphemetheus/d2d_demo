defmodule D2dDemoWeb.DashboardLive do
  use D2dDemoWeb, :live_view
  alias D2dDemo.LoRa

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(D2dDemo.PubSub, "lora:rx")
      Phoenix.PubSub.subscribe(D2dDemo.PubSub, "lora:tx")
    end

    {:ok,
     assign(socket,
       active_tab: :lora,
       lora_connected: LoRa.connected?(),
       lora_port: "/dev/ttyACM0",
       radio_settings: nil,
       tx_message: "",
       rx_messages: [],
       command_log: [],
       frequency: "868100000",
       spreading_factor: "7",
       bandwidth: "125",
       power: "14"
     )}
  end

  @impl true
  def handle_event("connect_lora", _params, socket) do
    case LoRa.connect(socket.assigns.lora_port) do
      :ok ->
        # Pause MAC for raw radio mode
        LoRa.pause_mac()
        {:ok, settings} = LoRa.get_radio_settings()

        {:noreply,
         socket
         |> assign(lora_connected: true, radio_settings: settings)
         |> add_log("Connected to #{socket.assigns.lora_port}")}

      {:error, reason} ->
        {:noreply, add_log(socket, "Connection failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("disconnect_lora", _params, socket) do
    LoRa.disconnect()

    {:noreply,
     socket
     |> assign(lora_connected: false, radio_settings: nil)
     |> add_log("Disconnected")}
  end

  @impl true
  def handle_event("update_port", %{"port" => port}, socket) do
    {:noreply, assign(socket, lora_port: port)}
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    case LoRa.transmit(message) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(tx_message: "")
         |> add_log("TX: #{message}")}

      {:error, reason} ->
        {:noreply, add_log(socket, "TX Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("update_tx_message", %{"message" => message}, socket) do
    {:noreply, assign(socket, tx_message: message)}
  end

  @impl true
  def handle_event("start_rx", _params, socket) do
    case LoRa.receive_mode(0) do
      {:ok, _} ->
        {:noreply, add_log(socket, "Listening for messages...")}

      {:error, reason} ->
        {:noreply, add_log(socket, "RX Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("set_frequency", %{"frequency" => freq}, socket) do
    socket = assign(socket, frequency: freq)

    if socket.assigns.lora_connected do
      case LoRa.set_frequency(freq) do
        {:ok, _} -> {:noreply, add_log(socket, "Frequency set to #{freq} Hz")}
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
        {:ok, _} -> {:noreply, add_log(socket, "SF set to #{sf}")}
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
        {:ok, _} -> {:noreply, add_log(socket, "Bandwidth set to #{bw} kHz")}
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
        {:ok, _} -> {:noreply, add_log(socket, "Power set to #{power} dBm")}
        {:error, reason} -> {:noreply, add_log(socket, "Error: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("send_raw_cmd", %{"cmd" => cmd}, socket) do
    case LoRa.send_command(cmd) do
      {:ok, response} ->
        {:noreply, add_log(socket, "> #{cmd}\n< #{response}")}

      {:error, reason} ->
        {:noreply, add_log(socket, "Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end

  @impl true
  def handle_info({:lora_rx, data}, socket) do
    message = %{
      data: data,
      timestamp: DateTime.utc_now(),
      hex: Base.encode16(data)
    }

    {:noreply,
     socket
     |> update(:rx_messages, fn msgs -> [message | Enum.take(msgs, 49)] end)
     |> add_log("RX: #{data} (#{message.hex})")}
  end

  @impl true
  def handle_info(:tx_ok, socket) do
    {:noreply, add_log(socket, "TX OK")}
  end

  @impl true
  def handle_info(:tx_error, socket) do
    {:noreply, add_log(socket, "TX ERROR")}
  end

  defp add_log(socket, message) do
    entry = %{
      message: message,
      timestamp: DateTime.utc_now()
    }

    update(socket, :command_log, fn log -> [entry | Enum.take(log, 99)] end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200 p-4">
      <div class="max-w-6xl mx-auto">
        <h1 class="text-3xl font-bold mb-6">D2D Communication Demo</h1>

        <!-- Connection Status -->
        <div class="card bg-base-100 shadow-xl mb-6">
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

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- Left Panel: Controls -->
          <div class="space-y-6">
            <!-- Radio Settings -->
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Radio Settings</h2>

                <div class="form-control">
                  <label class="label"><span class="label-text">Frequency (Hz)</span></label>
                  <select
                    class="select select-bordered"
                    phx-change="set_frequency"
                    name="frequency"
                    disabled={!@lora_connected}
                  >
                    <option value="868100000" selected={@frequency == "868100000"}>868.1 MHz (EU)</option>
                    <option value="868300000" selected={@frequency == "868300000"}>868.3 MHz (EU)</option>
                    <option value="868500000" selected={@frequency == "868500000"}>868.5 MHz (EU)</option>
                    <option value="915000000" selected={@frequency == "915000000"}>915.0 MHz (US)</option>
                  </select>
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Spreading Factor</span></label>
                  <select
                    class="select select-bordered"
                    phx-change="set_sf"
                    name="sf"
                    disabled={!@lora_connected}
                  >
                    <%= for sf <- 7..12 do %>
                      <option value={sf} selected={@spreading_factor == to_string(sf)}>SF<%= sf %></option>
                    <% end %>
                  </select>
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Bandwidth (kHz)</span></label>
                  <select
                    class="select select-bordered"
                    phx-change="set_bw"
                    name="bw"
                    disabled={!@lora_connected}
                  >
                    <option value="125" selected={@bandwidth == "125"}>125 kHz</option>
                    <option value="250" selected={@bandwidth == "250"}>250 kHz</option>
                    <option value="500" selected={@bandwidth == "500"}>500 kHz</option>
                  </select>
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">TX Power (dBm)</span></label>
                  <input
                    type="range"
                    min="-3"
                    max="14"
                    value={@power}
                    class="range"
                    phx-change="set_power"
                    name="power"
                    disabled={!@lora_connected}
                  />
                  <div class="text-center"><%= @power %> dBm</div>
                </div>
              </div>
            </div>

            <!-- Transmit -->
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Transmit</h2>
                <form phx-submit="send_message" class="flex gap-2">
                  <input
                    type="text"
                    name="message"
                    value={@tx_message}
                    phx-change="update_tx_message"
                    class="input input-bordered flex-1"
                    placeholder="Message to send..."
                    disabled={!@lora_connected}
                  />
                  <button type="submit" class="btn btn-primary" disabled={!@lora_connected}>
                    Send
                  </button>
                </form>
                <button
                  phx-click="start_rx"
                  class="btn btn-secondary mt-2"
                  disabled={!@lora_connected}
                >
                  Start Listening
                </button>
              </div>
            </div>

            <!-- Raw Command -->
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Raw Command</h2>
                <form phx-submit="send_raw_cmd" class="flex gap-2">
                  <input
                    type="text"
                    name="cmd"
                    class="input input-bordered flex-1 font-mono"
                    placeholder="radio get freq"
                    disabled={!@lora_connected}
                  />
                  <button type="submit" class="btn btn-outline" disabled={!@lora_connected}>
                    Execute
                  </button>
                </form>
              </div>
            </div>
          </div>

          <!-- Right Panel: Log -->
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title">Activity Log</h2>
              <div class="bg-base-300 rounded-lg p-4 h-96 overflow-y-auto font-mono text-sm">
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

        <!-- Received Messages -->
        <%= if @rx_messages != [] do %>
          <div class="card bg-base-100 shadow-xl mt-6">
            <div class="card-body">
              <h2 class="card-title">Received Messages</h2>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr>
                      <th>Time</th>
                      <th>Data</th>
                      <th>Hex</th>
                    </tr>
                  </thead>
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
      </div>
    </div>
    """
  end
end

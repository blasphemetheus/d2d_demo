defmodule D2dDemo.Network.WiFi do
  @moduledoc """
  GenServer for WiFi ad-hoc network management on Laptop.
  Connect/disconnect on demand (not auto-start).
  """
  use GenServer
  require Logger

  @default_interface "wlp0s20f3"
  @default_ssid "PiAdhoc"
  @default_freq "2437"
  @default_ip "192.168.12.2"
  @peer_ip "192.168.12.1"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def setup(interface \\ @default_interface) do
    GenServer.call(__MODULE__, {:setup, interface}, 30_000)
  end

  def teardown do
    GenServer.call(__MODULE__, :teardown, 30_000)
  end

  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  def get_rssi do
    GenServer.call(__MODULE__, :get_rssi)
  end

  def get_peer_ip do
    @peer_ip
  end

  def reset_network_manager do
    GenServer.call(__MODULE__, :reset_network_manager, 30_000)
  end

  def get_interface do
    GenServer.call(__MODULE__, :get_interface)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    state = %{
      interface: Keyword.get(opts, :interface, @default_interface),
      connected: false,
      ip: @default_ip,
      peer_ip: @peer_ip
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:setup, interface}, _from, state) do
    case do_setup(interface) do
      :ok ->
        D2dDemo.FileLogger.log_event("WIFI_CONNECTED: #{interface} at #{state.ip}")
        Phoenix.PubSub.broadcast(D2dDemo.PubSub, "network:wifi:status", {:wifi_connected, true})
        {:reply, :ok, %{state | interface: interface, connected: true}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:teardown, _from, state) do
    do_teardown(state.interface)
    D2dDemo.FileLogger.log_event("WIFI_DISCONNECTED: #{state.interface}")
    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "network:wifi:status", {:wifi_connected, false})
    {:reply, :ok, %{state | connected: false}}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call(:get_interface, _from, state) do
    {:reply, state.interface, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    rssi = if state.connected, do: fetch_rssi(state.interface), else: nil

    status = %{
      connected: state.connected,
      interface: state.interface,
      ip: state.ip,
      peer_ip: state.peer_ip,
      rssi: rssi
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_rssi, _from, state) do
    rssi = if state.connected, do: fetch_rssi(state.interface), else: nil
    {:reply, rssi, state}
  end

  @impl true
  def handle_call(:reset_network_manager, _from, state) do
    do_reset_network_manager()
    D2dDemo.FileLogger.log_event("WIFI_RESET: NetworkManager restored")
    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "network:wifi:status", {:wifi_connected, false})
    {:reply, :ok, %{state | connected: false}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.connected do
      Logger.info("WiFi: Cleaning up ad-hoc network...")
      do_teardown(state.interface)
    end
    :ok
  end

  # Private functions

  defp do_setup(interface) do
    script = scripts_path("wifi_setup.sh")
    args = [interface, @default_ssid, @default_freq, @default_ip]

    case System.cmd("sudo", [script | args], stderr_to_stdout: true) do
      {output, 0} ->
        Logger.debug("WiFi setup output: #{output}")
        :ok

      {output, code} ->
        Logger.error("WiFi setup failed (exit #{code}): #{output}")
        {:error, output}
    end
  end

  defp do_teardown(interface) do
    script = scripts_path("wifi_teardown.sh")

    case System.cmd("sudo", [script, interface], stderr_to_stdout: true) do
      {output, 0} ->
        Logger.debug("WiFi teardown output: #{output}")
        :ok

      {output, code} ->
        Logger.warning("WiFi teardown issue (exit #{code}): #{output}")
        :ok
    end
  end

  defp do_reset_network_manager do
    # Just restart NetworkManager - it will reclaim the interface
    case System.cmd("sudo", ["systemctl", "restart", "NetworkManager"], stderr_to_stdout: true) do
      {output, 0} ->
        Logger.debug("NetworkManager restart output: #{output}")
        :ok

      {output, code} ->
        Logger.warning("NetworkManager restart issue (exit #{code}): #{output}")
        :ok
    end
  end

  defp fetch_rssi(interface) do
    # Try iw first (more modern), then iwconfig
    case System.find_executable("iw") do
      nil -> fetch_rssi_iwconfig(interface)
      _path ->
        case System.cmd("iw", ["dev", interface, "link"], stderr_to_stdout: true) do
          {output, 0} ->
            case Regex.run(~r/signal:\s*(-?\d+)\s*dBm/i, output) do
              [_, rssi] -> String.to_integer(rssi)
              _ -> nil
            end
          _ -> nil
        end
    end
  end

  defp fetch_rssi_iwconfig(interface) do
    case System.find_executable("iwconfig") do
      nil -> nil
      _path ->
        case System.cmd("iwconfig", [interface], stderr_to_stdout: true) do
          {output, 0} ->
            case Regex.run(~r/Signal level[=:](-?\d+)\s*dBm/i, output) do
              [_, rssi] -> String.to_integer(rssi)
              _ -> nil
            end
          _ -> nil
        end
    end
  end

  defp scripts_path(script_name) do
    :code.priv_dir(:d2d_demo)
    |> to_string()
    |> Path.join("scripts/#{script_name}")
  end
end

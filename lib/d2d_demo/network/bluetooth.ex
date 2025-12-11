defmodule D2dDemo.Network.Bluetooth do
  @moduledoc """
  GenServer for Bluetooth PAN PANU client on Laptop.
  Connect/disconnect on demand.
  """
  use GenServer
  require Logger

  @default_peer_mac "B8:27:EB:D6:9C:95"
  @default_ip "192.168.44.2"
  @peer_ip "192.168.44.1"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def connect(peer_mac \\ @default_peer_mac, ip \\ @default_ip) do
    GenServer.call(__MODULE__, {:connect, peer_mac, ip}, 60_000)
  end

  def disconnect do
    GenServer.call(__MODULE__, :disconnect, 30_000)
  end

  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  def get_peer_ip do
    @peer_ip
  end

  def get_peer_mac do
    GenServer.call(__MODULE__, :get_peer_mac)
  end

  def set_peer_mac(mac) do
    GenServer.call(__MODULE__, {:set_peer_mac, mac})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    # Check if already connected (bnep0 exists with correct IP)
    connected = check_existing_connection()

    if connected do
      Logger.info("Bluetooth: Detected existing bnep0 connection")
    end

    state = %{
      connected: connected,
      peer_mac: Keyword.get(opts, :peer_mac, @default_peer_mac),
      ip: @default_ip,
      peer_ip: @peer_ip
    }

    {:ok, state}
  end

  defp check_existing_connection do
    case System.cmd("ip", ["addr", "show", "bnep0"], stderr_to_stdout: true) do
      {output, 0} ->
        # Check if our IP is assigned
        String.contains?(output, @default_ip)
      _ ->
        false
    end
  end

  @impl true
  def handle_call({:connect, peer_mac, ip}, _from, state) do
    case do_connect(peer_mac, ip) do
      :ok ->
        D2dDemo.FileLogger.log_event("BT_CONNECTED: #{peer_mac} at #{ip}")
        Phoenix.PubSub.broadcast(D2dDemo.PubSub, "network:bluetooth:status", {:bt_connected, true})
        {:reply, :ok, %{state | peer_mac: peer_mac, ip: ip, connected: true}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:disconnect, _from, state) do
    do_disconnect(state.peer_mac)
    D2dDemo.FileLogger.log_event("BT_DISCONNECTED: #{state.peer_mac}")
    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "network:bluetooth:status", {:bt_connected, false})
    {:reply, :ok, %{state | connected: false}}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call(:get_peer_mac, _from, state) do
    {:reply, state.peer_mac, state}
  end

  @impl true
  def handle_call({:set_peer_mac, mac}, _from, state) do
    {:reply, :ok, %{state | peer_mac: mac}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      connected: state.connected,
      mode: :client,
      interface: "bnep0",
      peer_mac: state.peer_mac,
      ip: state.ip,
      peer_ip: state.peer_ip
    }
    {:reply, status, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.connected do
      Logger.info("Bluetooth: Disconnecting...")
      do_disconnect(state.peer_mac)
    end
    :ok
  end

  # Private functions

  defp do_connect(peer_mac, ip) do
    script = scripts_path("bt_connect.sh")
    Logger.info("Bluetooth: Running connect script: sudo #{script} #{peer_mac} #{ip}")

    task = Task.async(fn ->
      System.cmd("sudo", [script, peer_mac, ip], stderr_to_stdout: true)
    end)

    case Task.yield(task, 45_000) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        Logger.info("Bluetooth connect output: #{output}")
        :ok

      {:ok, {output, code}} ->
        Logger.error("Bluetooth connect failed (exit #{code}): #{output}")
        {:error, output}

      nil ->
        Logger.error("Bluetooth connect timed out after 45 seconds")
        {:error, "Connection timed out"}
    end
  end

  defp do_disconnect(peer_mac) do
    script = scripts_path("bt_disconnect.sh")

    case System.cmd("sudo", [script, peer_mac], stderr_to_stdout: true) do
      {output, 0} ->
        Logger.debug("Bluetooth disconnect output: #{output}")
        :ok

      {output, code} ->
        Logger.warning("Bluetooth disconnect issue (exit #{code}): #{output}")
        :ok
    end
  end

  defp scripts_path(script_name) do
    :code.priv_dir(:d2d_demo)
    |> to_string()
    |> Path.join("scripts/#{script_name}")
  end
end

defmodule D2dDemo.Beacon do
  @moduledoc """
  Periodically transmits beacon messages via LoRa.
  Broadcasts status updates via PubSub for LiveView integration.
  """
  use GenServer
  require Logger
  alias D2dDemo.LoRa

  @default_interval 3_000
  @default_message "PING"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_beacon(opts \\ []) do
    GenServer.call(__MODULE__, {:start, opts})
  end

  def stop_beacon do
    GenServer.call(__MODULE__, :stop)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def running? do
    GenServer.call(__MODULE__, :running?)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok,
     %{
       running: false,
       message: @default_message,
       interval: @default_interval,
       timer_ref: nil,
       tx_count: 0
     }}
  end

  @impl true
  def handle_call({:start, opts}, _from, state) do
    if state.running do
      {:reply, {:error, :already_running}, state}
    else
      message = Keyword.get(opts, :message, state.message)
      interval = Keyword.get(opts, :interval, state.interval)

      # Send first beacon immediately
      send(self(), :send_beacon)

      Logger.info("Beacon started: '#{message}' every #{interval}ms")
      broadcast_status(true, message, interval, 0)

      {:reply, :ok,
       %{state | running: true, message: message, interval: interval, tx_count: 0}}
    end
  end

  @impl true
  def handle_call(:stop, _from, state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    Logger.info("Beacon stopped after #{state.tx_count} transmissions")
    broadcast_status(false, state.message, state.interval, state.tx_count)

    {:reply, :ok, %{state | running: false, timer_ref: nil}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       running: state.running,
       message: state.message,
       interval: state.interval,
       tx_count: state.tx_count
     }, state}
  end

  @impl true
  def handle_call(:running?, _from, state) do
    {:reply, state.running, state}
  end

  @impl true
  def handle_info(:send_beacon, state) do
    if state.running do
      # Transmit the beacon
      case LoRa.transmit(state.message) do
        {:ok, _} ->
          Logger.debug("Beacon TX ##{state.tx_count + 1}: #{state.message}")
          broadcast_tx(state.message, state.tx_count + 1)

        {:error, reason} ->
          Logger.warning("Beacon TX failed: #{inspect(reason)}")
      end

      # Schedule next beacon
      timer_ref = Process.send_after(self(), :send_beacon, state.interval)

      {:noreply, %{state | timer_ref: timer_ref, tx_count: state.tx_count + 1}}
    else
      {:noreply, state}
    end
  end

  defp broadcast_status(running, message, interval, tx_count) do
    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "beacon:status",
      {:beacon_status, %{running: running, message: message, interval: interval, tx_count: tx_count}})
  end

  defp broadcast_tx(message, count) do
    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "beacon:tx", {:beacon_tx, message, count})
  end
end

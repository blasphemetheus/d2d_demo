defmodule D2dDemo.Ping do
  @moduledoc """
  LoRa ping test - sends a message and measures round-trip time
  when the echo response is received.
  """
  use GenServer
  require Logger
  alias D2dDemo.LoRa

  @default_timeout 10_000
  @ping_prefix "PING:"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a single ping and wait for response.
  Returns {:ok, rtt_ms} or {:error, :timeout}
  """
  def ping(opts \\ []) do
    GenServer.call(__MODULE__, {:ping, opts}, 15_000)
  end

  @doc """
  Run a ping test with multiple pings.
  Results are broadcast via PubSub.
  """
  def run_test(count \\ 5, opts \\ []) do
    GenServer.cast(__MODULE__, {:run_test, count, opts})
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
    # Subscribe to LoRa RX and TX events
    Phoenix.PubSub.subscribe(D2dDemo.PubSub, "lora:rx")
    Phoenix.PubSub.subscribe(D2dDemo.PubSub, "lora:tx")

    {:ok,
     %{
       running: false,
       pending_ping: nil,
       waiting_for_tx_ok: false,
       results: [],
       test_count: 0,
       test_total: 0
     }}
  end

  @impl true
  def handle_call({:ping, opts}, from, state) do
    if state.pending_ping do
      {:reply, {:error, :ping_in_progress}, state}
    else
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      seq = System.unique_integer([:positive]) |> rem(10000)
      message = "#{@ping_prefix}#{seq}"
      sent_at = System.monotonic_time(:millisecond)

      case LoRa.transmit(message) do
        {:ok, _} ->
          # Start timeout timer
          timer_ref = Process.send_after(self(), {:ping_timeout, seq}, timeout)

          # Wait for tx_ok before entering RX mode (TX takes ~1s at SF12)
          {:noreply,
           %{state |
             pending_ping: %{
               from: from,
               seq: seq,
               sent_at: sent_at,
               timer_ref: timer_ref
             },
             waiting_for_tx_ok: true
           }}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{running: state.running, results: state.results}, state}
  end

  @impl true
  def handle_call(:running?, _from, state) do
    {:reply, state.running, state}
  end

  @impl true
  def handle_cast({:run_test, count, opts}, state) do
    if state.running do
      {:noreply, state}
    else
      broadcast_test_started(count)
      send(self(), {:run_next_ping, opts})
      {:noreply, %{state | running: true, results: [], test_count: 0, test_total: count}}
    end
  end

  @impl true
  def handle_info({:lora_rx, data}, state) do
    if state.pending_ping do
      ping = state.pending_ping
      # Check if this is our ping response (echo will have ACK: or similar prefix)
      seq_str = "#{ping.seq}"

      if String.contains?(data, seq_str) do
        # Cancel timeout
        Process.cancel_timer(ping.timer_ref)

        # Calculate RTT
        rtt = System.monotonic_time(:millisecond) - ping.sent_at
        Logger.info("Ping RTT: #{rtt}ms (seq=#{ping.seq})")

        # Check if this is a single ping (has caller) or test mode (from: nil)
        if ping.from do
          # Single ping - reply to caller
          GenServer.reply(ping.from, {:ok, rtt})
          {:noreply, %{state | pending_ping: nil}}
        else
          # Test mode - record result and continue
          result = %{seq: ping.seq, rtt: rtt, error: nil}
          broadcast_ping_result(result, state.test_count, state.test_total)

          # Schedule next ping
          Process.send_after(self(), {:run_next_ping, ping.opts}, 500)

          {:noreply, %{state | pending_ping: nil, results: [result | state.results]}}
        end
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ping_timeout, seq}, state) do
    if state.pending_ping && state.pending_ping.seq == seq do
      Logger.warning("Ping timeout (seq=#{seq})")
      if state.pending_ping.from do
        GenServer.reply(state.pending_ping.from, {:error, :timeout})
      end
      {:noreply, %{state | pending_ping: nil, waiting_for_tx_ok: false}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:tx_ok, state) do
    if state.waiting_for_tx_ok and state.pending_ping do
      # TX complete, now enter RX mode to listen for response
      Logger.debug("Ping: TX complete, entering RX mode")
      LoRa.receive_mode(0)
      {:noreply, %{state | waiting_for_tx_ok: false}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:tx_error, state) do
    if state.waiting_for_tx_ok and state.pending_ping do
      Logger.warning("Ping: TX error")
      if state.pending_ping.from do
        Process.cancel_timer(state.pending_ping.timer_ref)
        GenServer.reply(state.pending_ping.from, {:error, :tx_error})
      end
      {:noreply, %{state | pending_ping: nil, waiting_for_tx_ok: false}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:run_next_ping, opts}, state) do
    if state.test_count >= state.test_total do
      # Test complete
      broadcast_test_complete(state.results)
      {:noreply, %{state | running: false}}
    else
      # Run next ping
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      seq = System.unique_integer([:positive]) |> rem(10000)
      message = "#{@ping_prefix}#{seq}"
      sent_at = System.monotonic_time(:millisecond)

      case LoRa.transmit(message) do
        {:ok, _} ->
          # Wait for tx_ok before entering RX mode
          timer_ref = Process.send_after(self(), {:test_ping_timeout, seq, opts}, timeout)

          {:noreply,
           %{state |
             pending_ping: %{
               from: nil,  # No caller to reply to
               seq: seq,
               sent_at: sent_at,
               timer_ref: timer_ref,
               opts: opts
             },
             waiting_for_tx_ok: true,
             test_count: state.test_count + 1
           }}

        {:error, _reason} ->
          # Record failure and continue
          result = %{seq: seq, rtt: nil, error: :tx_failed}
          broadcast_ping_result(result, state.test_count + 1, state.test_total)

          # Schedule next ping
          Process.send_after(self(), {:run_next_ping, opts}, 500)

          {:noreply, %{state | results: [result | state.results], test_count: state.test_count + 1}}
      end
    end
  end

  @impl true
  def handle_info({:test_ping_timeout, seq, opts}, state) do
    if state.pending_ping && state.pending_ping.seq == seq do
      result = %{seq: seq, rtt: nil, error: :timeout}
      broadcast_ping_result(result, state.test_count, state.test_total)

      # Schedule next ping
      Process.send_after(self(), {:run_next_ping, opts}, 500)

      {:noreply, %{state | pending_ping: nil, waiting_for_tx_ok: false, results: [result | state.results]}}
    else
      {:noreply, state}
    end
  end

  defp broadcast_test_started(count) do
    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "ping:status", {:ping_test_started, count})
  end

  defp broadcast_ping_result(result, current, total) do
    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "ping:result", {:ping_result, result, current, total})
  end

  defp broadcast_test_complete(results) do
    successful = Enum.filter(results, & &1.rtt)
    failed = length(results) - length(successful)

    stats = if length(successful) > 0 do
      rtts = Enum.map(successful, & &1.rtt)
      %{
        min: Enum.min(rtts),
        max: Enum.max(rtts),
        avg: Float.round(Enum.sum(rtts) / length(rtts), 1),
        success: length(successful),
        failed: failed,
        total: length(results)
      }
    else
      %{min: nil, max: nil, avg: nil, success: 0, failed: failed, total: length(results)}
    end

    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "ping:status", {:ping_test_complete, stats})
  end
end

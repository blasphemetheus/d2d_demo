defmodule D2dDemo.LoRaTestRunner do
  @moduledoc """
  LoRa performance test runner - ping and throughput tests.
  Matches the structure of Network.TestRunner for consistency.
  """
  use GenServer
  require Logger
  alias D2dDemo.LoRa

  @ping_prefix "PING:"
  @throughput_prefix "TPT:"
  @default_ping_timeout 15_000
  @default_throughput_timeout 30_000
  @payload_size 50  # bytes per packet for throughput test

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run LoRa ping test. Returns detailed result map matching WiFi/BT format.
  """
  def run_ping(count \\ 5, opts \\ []) do
    GenServer.call(__MODULE__, {:run_ping, count, opts}, 120_000)
  end

  @doc """
  Run LoRa throughput test. Sends packets and measures effective bitrate.
  """
  def run_throughput(packet_count \\ 10, opts \\ []) do
    GenServer.call(__MODULE__, {:run_throughput, packet_count, opts}, 120_000)
  end

  def running? do
    GenServer.call(__MODULE__, :running?)
  end

  @doc """
  Run a complete field test at a given distance/location.
  Runs ping test and prints summary. All results are logged with the label.

  ## Examples

      iex> D2dDemo.LoRaTestRunner.field_test("100m")
      iex> D2dDemo.LoRaTestRunner.field_test("500m", ping_count: 10)
  """
  def field_test(label, opts \\ []) do
    ping_count = Keyword.get(opts, :ping_count, 5)

    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("FIELD TEST: #{label}")
    IO.puts(String.duplicate("=", 50))

    # Run ping test
    IO.puts("\n📡 Running #{ping_count} pings...")
    ping_result = run_ping(ping_count, label: label)

    case ping_result do
      %{packets_sent: sent, packets_received: recv, rtt_avg_ms: avg, rtt_min_ms: min, rtt_max_ms: max} ->
        loss = Float.round((sent - recv) / sent * 100, 1)
        IO.puts("✓ Ping: #{recv}/#{sent} received (#{loss}% loss)")
        if avg, do: IO.puts("  RTT: avg=#{avg}ms, min=#{min}ms, max=#{max}ms")

      _ ->
        IO.puts("✗ Ping test failed")
    end

    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("Results logged with label: #{label}")
    IO.puts(String.duplicate("=", 50) <> "\n")

    ping_result
  end

  @doc """
  Quick connectivity check - sends one ping to verify the remote is responding.
  """
  def check_connection do
    IO.puts("Checking connection...")
    case run_ping(1, timeout: 5_000) do
      %{packets_received: 1, rtt_avg_ms: rtt} ->
        IO.puts("✓ Connected! RTT: #{rtt}ms")
        :ok

      _ ->
        IO.puts("✗ No response from remote")
        :error
    end
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(D2dDemo.PubSub, "lora:rx")
    Phoenix.PubSub.subscribe(D2dDemo.PubSub, "lora:tx")

    {:ok, %{
      running: false,
      test_type: nil,
      pending: nil,
      waiting_for_tx_ok: false,
      results: [],
      test_count: 0,
      test_total: 0,
      start_time: nil,
      opts: []
    }}
  end

  @impl true
  def handle_call({:run_ping, count, opts}, from, state) do
    if state.running do
      {:reply, {:error, :test_in_progress}, state}
    else
      label = Keyword.get(opts, :label, "")
      broadcast(:lora_test, {:test_started, :ping, :lora})

      # Start first ping
      send(self(), :run_next_ping)

      {:noreply, %{state |
        running: true,
        test_type: :ping,
        pending: %{from: from, label: label},
        results: [],
        test_count: 0,
        test_total: count,
        start_time: System.monotonic_time(:millisecond),
        opts: opts
      }}
    end
  end

  @impl true
  def handle_call({:run_throughput, packet_count, opts}, from, state) do
    if state.running do
      {:reply, {:error, :test_in_progress}, state}
    else
      label = Keyword.get(opts, :label, "")
      broadcast(:lora_test, {:test_started, :throughput, :lora})

      # Start sending packets
      send(self(), :run_next_throughput)

      {:noreply, %{state |
        running: true,
        test_type: :throughput,
        pending: %{from: from, label: label},
        results: [],
        test_count: 0,
        test_total: packet_count,
        start_time: System.monotonic_time(:millisecond),
        opts: opts
      }}
    end
  end

  @impl true
  def handle_call(:running?, _from, state) do
    {:reply, state.running, state}
  end

  # Ping test logic

  @impl true
  def handle_info(:run_next_ping, %{test_type: :ping} = state) do
    if state.test_count >= state.test_total do
      # Test complete
      finish_ping_test(state)
    else
      # Send next ping
      seq = System.unique_integer([:positive]) |> rem(10000)
      message = "#{@ping_prefix}#{seq}"
      sent_at = System.monotonic_time(:millisecond)

      case LoRa.transmit(message) do
        {:ok, _} ->
          timeout = Keyword.get(state.opts, :timeout, @default_ping_timeout)
          timer_ref = Process.send_after(self(), {:ping_timeout, seq}, timeout)

          {:noreply, %{state |
            pending: Map.merge(state.pending, %{
              seq: seq,
              sent_at: sent_at,
              timer_ref: timer_ref
            }),
            waiting_for_tx_ok: true,
            test_count: state.test_count + 1
          }}

        {:error, reason} ->
          # Record TX failure
          result = %{seq: seq, rtt: nil, error: reason, timestamp: DateTime.utc_now()}
          broadcast(:lora_ping, {:lora_ping_result, result, state.test_count + 1, state.test_total})

          Process.send_after(self(), :run_next_ping, 500)
          {:noreply, %{state | results: [result | state.results], test_count: state.test_count + 1}}
      end
    end
  end

  @impl true
  def handle_info({:ping_timeout, seq}, %{test_type: :ping, pending: %{seq: pending_seq}} = state)
      when seq == pending_seq do
    result = %{seq: seq, rtt: nil, error: :timeout, timestamp: DateTime.utc_now()}
    broadcast(:lora_ping, {:lora_ping_result, result, state.test_count, state.test_total})

    Process.send_after(self(), :run_next_ping, 500)
    {:noreply, %{state |
      pending: Map.drop(state.pending, [:seq, :sent_at, :timer_ref]),
      waiting_for_tx_ok: false,
      results: [result | state.results]
    }}
  end

  # Throughput test logic

  @impl true
  def handle_info(:run_next_throughput, %{test_type: :throughput} = state) do
    if state.test_count >= state.test_total do
      finish_throughput_test(state)
    else
      # Generate payload
      seq = state.test_count + 1
      # Pad to fixed size for consistent measurement
      payload = "#{@throughput_prefix}#{seq}:" <> String.duplicate("X", @payload_size - 10)
      sent_at = System.monotonic_time(:millisecond)

      case LoRa.transmit(payload) do
        {:ok, _} ->
          {:noreply, %{state |
            pending: Map.merge(state.pending, %{seq: seq, sent_at: sent_at}),
            waiting_for_tx_ok: true,
            test_count: state.test_count + 1
          }}

        {:error, reason} ->
          result = %{seq: seq, success: false, error: reason}
          Process.send_after(self(), :run_next_throughput, 100)
          {:noreply, %{state | results: [result | state.results], test_count: state.test_count + 1}}
      end
    end
  end

  # TX complete handlers

  @impl true
  def handle_info(:tx_ok, %{waiting_for_tx_ok: true, test_type: :ping} = state) do
    # TX done, enter RX mode with timeout matching ping timeout
    # Don't use 0 (continuous) - radio won't exit RX mode on software timeout
    timeout = Keyword.get(state.opts, :timeout, @default_ping_timeout)
    LoRa.receive_mode(timeout)
    {:noreply, %{state | waiting_for_tx_ok: false}}
  end

  @impl true
  def handle_info(:tx_ok, %{waiting_for_tx_ok: true, test_type: :throughput} = state) do
    # For throughput, just record success and continue
    result = %{seq: state.pending.seq, success: true, tx_time: System.monotonic_time(:millisecond) - state.pending.sent_at}
    broadcast(:lora_throughput, {:throughput_progress, state.test_count, state.test_total})

    # Small delay between packets
    Process.send_after(self(), :run_next_throughput, 100)
    {:noreply, %{state | waiting_for_tx_ok: false, results: [result | state.results]}}
  end

  @impl true
  def handle_info(:tx_error, %{waiting_for_tx_ok: true} = state) do
    # TX failed
    result = %{seq: state.pending[:seq], success: false, error: :tx_error}

    case state.test_type do
      :ping ->
        if state.pending[:timer_ref], do: Process.cancel_timer(state.pending.timer_ref)
        broadcast(:lora_ping, {:lora_ping_result, result, state.test_count, state.test_total})
        Process.send_after(self(), :run_next_ping, 500)

      :throughput ->
        broadcast(:lora_throughput, {:throughput_progress, state.test_count, state.test_total})
        Process.send_after(self(), :run_next_throughput, 100)
    end

    {:noreply, %{state | waiting_for_tx_ok: false, results: [result | state.results]}}
  end

  # RX handler for ping responses

  @impl true
  def handle_info({:lora_rx, data}, %{test_type: :ping, pending: %{seq: seq, sent_at: sent_at, timer_ref: timer_ref}} = state) do
    if String.contains?(data, "#{seq}") do
      Process.cancel_timer(timer_ref)
      rtt = System.monotonic_time(:millisecond) - sent_at

      result = %{seq: seq, rtt: rtt, error: nil, timestamp: DateTime.utc_now()}
      broadcast(:lora_ping, {:lora_ping_result, result, state.test_count, state.test_total})

      Process.send_after(self(), :run_next_ping, 500)
      {:noreply, %{state |
        pending: Map.drop(state.pending, [:seq, :sent_at, :timer_ref]),
        results: [result | state.results]
      }}
    else
      {:noreply, state}
    end
  end

  # Catch-all for other messages
  @impl true
  def handle_info({:ping_timeout, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:lora_rx, _}, state), do: {:noreply, state}
  @impl true
  def handle_info(:tx_ok, state), do: {:noreply, state}
  @impl true
  def handle_info(:tx_error, state), do: {:noreply, state}
  @impl true
  def handle_info(:run_next_ping, state), do: {:noreply, state}
  @impl true
  def handle_info(:run_next_throughput, state), do: {:noreply, state}

  # Test completion

  defp finish_ping_test(state) do
    total_time = System.monotonic_time(:millisecond) - state.start_time
    # Use Map.get to safely handle results that don't have :rtt key (tx_errors)
    successful = Enum.filter(state.results, &Map.get(&1, :rtt))
    rtts = Enum.map(successful, &Map.get(&1, :rtt))

    result = %{
      test_type: :ping,
      transport: :lora,
      timestamp: DateTime.utc_now(),
      label: state.pending.label,
      # Matching WiFi/BT format
      packets_sent: state.test_total,
      packets_received: length(successful),
      packet_loss_percent: Float.round((state.test_total - length(successful)) / state.test_total * 100, 1),
      rtt_min_ms: if(rtts != [], do: Enum.min(rtts), else: nil),
      rtt_avg_ms: if(rtts != [], do: Float.round(Enum.sum(rtts) / length(rtts), 1), else: nil),
      rtt_max_ms: if(rtts != [], do: Enum.max(rtts), else: nil),
      rtt_stddev_ms: if(length(rtts) > 1, do: Float.round(stddev(rtts), 1), else: 0.0),
      total_time_ms: total_time,
      individual_results: Enum.reverse(state.results)
    }

    broadcast(:lora_test, {:test_complete, :ping, result})
    D2dDemo.FileLogger.log_network_test(:lora, :ping, result)

    GenServer.reply(state.pending.from, result)
    {:noreply, reset_state(state)}
  end

  defp finish_throughput_test(state) do
    total_time = System.monotonic_time(:millisecond) - state.start_time
    successful = Enum.filter(state.results, & &1.success)
    bytes_sent = length(successful) * @payload_size
    bits_sent = bytes_sent * 8

    # Calculate effective bitrate
    bandwidth_bps = if total_time > 0, do: bits_sent / (total_time / 1000), else: 0
    bandwidth_kbps = Float.round(bandwidth_bps / 1000, 2)

    result = %{
      test_type: :throughput,
      transport: :lora,
      timestamp: DateTime.utc_now(),
      label: state.pending.label,
      # Throughput stats
      packets_sent: state.test_total,
      packets_successful: length(successful),
      packet_loss_percent: Float.round((state.test_total - length(successful)) / state.test_total * 100, 1),
      bytes_transferred: bytes_sent,
      duration_ms: total_time,
      bandwidth_kbps: bandwidth_kbps,
      bandwidth_bps: round(bandwidth_bps),
      payload_size: @payload_size
    }

    broadcast(:lora_test, {:test_complete, :throughput, result})
    D2dDemo.FileLogger.log_network_test(:lora, :throughput, result)

    GenServer.reply(state.pending.from, result)
    {:noreply, reset_state(state)}
  end

  defp reset_state(state) do
    %{state |
      running: false,
      test_type: nil,
      pending: nil,
      waiting_for_tx_ok: false,
      results: [],
      test_count: 0,
      test_total: 0,
      start_time: nil,
      opts: []
    }
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "#{topic}", message)
  end

  defp stddev(list) when length(list) < 2, do: 0.0
  defp stddev(list) do
    mean = Enum.sum(list) / length(list)
    variance = Enum.sum(Enum.map(list, fn x -> :math.pow(x - mean, 2) end)) / length(list)
    :math.sqrt(variance)
  end
end

defmodule D2dDemo.Network.TestRunner do
  @moduledoc """
  GenServer for running network performance tests (ping, iperf3).
  Broadcasts results via PubSub.
  """
  use GenServer
  require Logger

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run ping test to target IP. Returns result map with latency stats.
  """
  def run_ping(target_ip, count \\ 10, opts \\ []) do
    GenServer.call(__MODULE__, {:run_ping, target_ip, count, opts}, 60_000)
  end

  @doc """
  Run iperf3 throughput test to target IP. Returns result map with bandwidth.
  """
  def run_throughput(target_ip, duration \\ 10, opts \\ []) do
    GenServer.call(__MODULE__, {:run_throughput, target_ip, duration, opts}, 120_000)
  end

  @doc """
  Check if a test is currently running.
  """
  def test_running? do
    GenServer.call(__MODULE__, :test_running?)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{running: false}}
  end

  @impl true
  def handle_call({:run_ping, target_ip, count, opts}, _from, state) do
    transport = Keyword.get(opts, :transport, :unknown)
    label = Keyword.get(opts, :label, "")

    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "network:test", {:test_started, :ping, transport})

    result = do_ping(target_ip, count, transport) |> Map.put(:label, label)

    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "network:test", {:test_complete, :ping, result})
    D2dDemo.FileLogger.log_network_test(transport, :ping, result)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:run_throughput, target_ip, duration, opts}, _from, state) do
    transport = Keyword.get(opts, :transport, :unknown)
    label = Keyword.get(opts, :label, "")

    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "network:test", {:test_started, :throughput, transport})

    result = do_throughput(target_ip, duration, transport) |> Map.put(:label, label)

    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "network:test", {:test_complete, :throughput, result})
    D2dDemo.FileLogger.log_network_test(transport, :throughput, result)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:test_running?, _from, state) do
    {:reply, state.running, state}
  end

  # Private functions

  defp do_ping(target_ip, count, transport) do
    route_info = get_route_info(target_ip)

    case System.cmd("ping", ["-c", to_string(count), "-W", "2", target_ip], stderr_to_stdout: true) do
      {output, 0} ->
        parse_ping_output(output, target_ip, count, transport)
        |> Map.put(:route, route_info)

      {output, _code} ->
        # Partial success or failure - still try to parse
        result = parse_ping_output(output, target_ip, count, transport)
        result
        |> Map.put(:error, "Some packets may have been lost")
        |> Map.put(:route, route_info)
    end
  end

  defp parse_ping_output(output, target_ip, packets_sent, transport) do
    # Parse packet loss: "X packets transmitted, Y received, Z% packet loss"
    {packets_received, packet_loss} =
      case Regex.run(~r/(\d+) packets transmitted, (\d+) received.*?(\d+(?:\.\d+)?)% packet loss/, output) do
        [_, _sent, received, loss] ->
          {String.to_integer(received), parse_number(loss)}
        _ ->
          {0, 100.0}
      end

    # Parse RTT stats: "rtt min/avg/max/mdev = X/Y/Z/W ms"
    {rtt_min, rtt_avg, rtt_max, rtt_stddev} =
      case Regex.run(~r/rtt min\/avg\/max\/mdev = ([\d.]+)\/([\d.]+)\/([\d.]+)\/([\d.]+)/, output) do
        [_, min, avg, max, mdev] ->
          {parse_number(min), parse_number(avg), parse_number(max), parse_number(mdev)}
        _ ->
          {0.0, 0.0, 0.0, 0.0}
      end

    %{
      target_ip: target_ip,
      packets_sent: packets_sent,
      packets_received: packets_received,
      packet_loss_percent: packet_loss,
      rtt_min_ms: rtt_min,
      rtt_avg_ms: rtt_avg,
      rtt_max_ms: rtt_max,
      rtt_stddev_ms: rtt_stddev,
      timestamp: DateTime.utc_now(),
      transport: transport,
      test_type: :ping
    }
  end

  defp do_throughput(target_ip, duration, transport) do
    route_info = get_route_info(target_ip)

    case System.find_executable("iperf3") do
      nil ->
        %{
          error: "iperf3 not found",
          target_ip: target_ip,
          timestamp: DateTime.utc_now(),
          transport: transport,
          test_type: :throughput,
          route: route_info
        }

      _path ->
        args = ["-c", target_ip, "-t", to_string(duration), "-J"]

        case System.cmd("iperf3", args, stderr_to_stdout: true) do
          {output, 0} ->
            parse_iperf_output(output, target_ip, duration, transport)
            |> Map.put(:route, route_info)

          {output, _code} ->
            Logger.error("iperf3 failed: #{output}")
            %{
              error: "iperf3 failed: #{String.slice(output, 0, 100)}",
              target_ip: target_ip,
              timestamp: DateTime.utc_now(),
              transport: transport,
              test_type: :throughput,
              route: route_info
            }
        end
    end
  end

  defp parse_iperf_output(json_output, target_ip, duration, transport) do
    case Jason.decode(json_output) do
      {:ok, data} ->
        # Extract from iperf3 JSON output
        end_data = get_in(data, ["end", "sum_sent"]) || %{}

        bits_per_second = end_data["bits_per_second"] || 0
        bytes = end_data["bytes"] || 0
        retransmits = end_data["retransmits"] || 0

        %{
          target_ip: target_ip,
          duration_sec: duration,
          bandwidth_mbps: Float.round(bits_per_second / 1_000_000, 2),
          bytes_transferred: bytes,
          retransmits: retransmits,
          timestamp: DateTime.utc_now(),
          transport: transport,
          test_type: :throughput
        }

      {:error, _} ->
        # Fallback: try to parse text output
        bandwidth =
          case Regex.run(~r/([\d.]+)\s+Mbits\/sec/, json_output) do
            [_, mbps] -> String.to_float(mbps)
            _ -> 0.0
          end

        %{
          target_ip: target_ip,
          duration_sec: duration,
          bandwidth_mbps: bandwidth,
          bytes_transferred: 0,
          retransmits: 0,
          timestamp: DateTime.utc_now(),
          transport: transport,
          test_type: :throughput
        }
    end
  end

  # Parse a string as float, handling integers like "0" that String.to_float rejects
  defp parse_number(str) do
    case Float.parse(str) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  # Get routing information for a target IP using `ip route get`.
  # Returns a map with the interface and source IP that will be used.
  defp get_route_info(target_ip) do
    case System.cmd("ip", ["route", "get", target_ip], stderr_to_stdout: true) do
      {output, 0} ->
        # Parse output like: "192.168.12.1 dev wlp0s20f3 src 192.168.12.2 uid 1000"
        interface = case Regex.run(~r/dev\s+(\S+)/, output) do
          [_, dev] -> dev
          _ -> nil
        end

        source_ip = case Regex.run(~r/src\s+(\S+)/, output) do
          [_, src] -> src
          _ -> nil
        end

        %{
          interface: interface,
          source_ip: source_ip,
          raw: String.trim(output)
        }

      {output, _code} ->
        Logger.warning("Failed to get route info for #{target_ip}: #{output}")
        %{
          interface: nil,
          source_ip: nil,
          error: String.trim(output)
        }
    end
  end
end

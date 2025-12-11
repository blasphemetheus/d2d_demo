defmodule D2dDemo.FileLogger do
  @moduledoc """
  Logs LoRa TX/RX events and network tests to JSON Lines format for easy parsing.
  """
  use GenServer
  require Logger

  @log_dir "logs"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def log_tx(message, hex) do
    GenServer.cast(__MODULE__, {:log, :tx, message, hex})
  end

  def log_rx(message, hex) do
    GenServer.cast(__MODULE__, {:log, :rx, message, hex})
  end

  def log_event(event) do
    GenServer.cast(__MODULE__, {:log_event, event})
  end

  def log_network_test(transport, test_type, result) do
    GenServer.cast(__MODULE__, {:log_network_test, transport, test_type, result})
  end

  def get_log_path do
    GenServer.call(__MODULE__, :get_log_path)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    File.mkdir_p!(@log_dir)
    filename = generate_filename()
    path = Path.join(@log_dir, filename)
    {:ok, file} = File.open(path, [:append, :utf8])

    Logger.info("FileLogger: Writing to #{path}")

    {:ok, %{file: file, path: path}}
  end

  @impl true
  def handle_cast({:log, direction, message, hex}, state) do
    entry = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: "lora",
      direction: direction,
      message: message,
      hex: hex
    }
    write_json(state.file, entry)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:log_event, event}, state) do
    entry = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: "event",
      event: event
    }
    write_json(state.file, entry)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:log_network_test, transport, test_type, result}, state) do
    # Convert DateTime to ISO8601 string if present in result
    result = Map.update(result, :timestamp, nil, fn
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      other -> other
    end)

    entry = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: "network_test",
      transport: transport,
      test_type: test_type,
      result: result
    }
    write_json(state.file, entry)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_log_path, _from, state) do
    {:reply, state.path, state}
  end

  @impl true
  def terminate(_reason, state) do
    File.close(state.file)
  end

  # Private

  defp generate_filename do
    {{year, month, day}, {hour, min, sec}} = :calendar.local_time()
    "d2d_demo_#{year}#{pad(month)}#{pad(day)}_#{pad(hour)}#{pad(min)}#{pad(sec)}.jsonl"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp write_json(file, entry) do
    json = Jason.encode!(entry)
    IO.write(file, json <> "\n")
  end
end

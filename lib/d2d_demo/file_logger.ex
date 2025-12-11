defmodule D2dDemo.FileLogger do
  @moduledoc """
  Logs LoRa TX/RX events to timestamped files for field data collection.
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

    write_header(file)
    Logger.info("FileLogger: Writing to #{path}")

    {:ok, %{file: file, path: path}}
  end

  @impl true
  def handle_cast({:log, direction, message, hex}, state) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    dir_str = if direction == :tx, do: "TX", else: "RX"
    line = "#{timestamp}\t#{dir_str}\t#{inspect(message)}\t#{hex}\n"
    IO.write(state.file, line)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:log_event, event}, state) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    line = "#{timestamp}\tEVENT\t#{inspect(event)}\n"
    IO.write(state.file, line)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:log_network_test, transport, test_type, result}, state) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    transport_str = transport |> to_string() |> String.upcase()
    test_str = test_type |> to_string() |> String.upcase()
    line = "#{timestamp}\t#{transport_str}\t#{test_str}\t#{inspect(result)}\n"
    IO.write(state.file, line)
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
    "d2d_demo_#{year}#{pad(month)}#{pad(day)}_#{pad(hour)}#{pad(min)}#{pad(sec)}.log"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp write_header(file) do
    IO.write(file, "# D2D Demo Log\n")
    IO.write(file, "# Started: #{DateTime.utc_now() |> DateTime.to_iso8601()}\n")
    IO.write(file, "# Format: TIMESTAMP\tDIRECTION\tMESSAGE\tHEX\n")
    IO.write(file, "#\n")
  end
end

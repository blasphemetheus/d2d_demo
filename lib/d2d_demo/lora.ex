defmodule D2dDemo.LoRa do
  @moduledoc """
  GenServer for managing RN2903 LoRa module via serial port.
  Handles raw radio TX/RX operations.

  The RN2903 uses 57600 baud, 8N1, and requires CRLF line endings
  for both commands and responses.
  """
  use GenServer
  require Logger

  @default_port "/dev/ttyACM0"
  @default_baud 57600
  @command_timeout 3_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def connect(port \\ @default_port) do
    GenServer.call(__MODULE__, {:connect, port})
  end

  def disconnect do
    GenServer.call(__MODULE__, :disconnect)
  end

  def send_command(cmd) do
    GenServer.call(__MODULE__, {:send_command, cmd}, @command_timeout)
  end

  def get_info do
    GenServer.call(__MODULE__, :get_info)
  end

  def pause_mac do
    send_command("mac pause")
  end

  def transmit(data) when is_binary(data) do
    hex = Base.encode16(data)
    D2dDemo.FileLogger.log_tx(data, hex)
    send_command("radio tx #{hex}")
  end

  def receive_mode(timeout_ms \\ 0) do
    send_command("radio rx #{timeout_ms}")
  end

  def set_frequency(freq) do
    send_command("radio set freq #{freq}")
  end

  def set_spreading_factor(sf) when sf in 7..12 do
    send_command("radio set sf sf#{sf}")
  end

  def set_bandwidth(bw) when bw in [125, 250, 500] do
    send_command("radio set bw #{bw}")
  end

  def set_power(pwr) when pwr in -3..14 do
    send_command("radio set pwr #{pwr}")
  end

  def get_radio_settings do
    with {:ok, freq} <- send_command("radio get freq"),
         {:ok, sf} <- send_command("radio get sf"),
         {:ok, bw} <- send_command("radio get bw"),
         {:ok, pwr} <- send_command("radio get pwr"),
         {:ok, mod} <- send_command("radio get mod") do
      {:ok, %{
        frequency: freq,
        spreading_factor: sf,
        bandwidth: bw,
        power: pwr,
        modulation: mod
      }}
    end
  end

  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    state = %{
      uart: nil,
      port: nil,
      connected: false,
      pending_response: nil,
      buffer: "",
      subscribers: []
    }

    # Auto-connect if port specified
    if port = Keyword.get(opts, :port) do
      send(self(), {:auto_connect, port})
    end

    {:ok, state}
  end

  @impl true
  def handle_info({:auto_connect, port}, state) do
    case do_connect(port, state) do
      {:ok, new_state} ->
        Logger.info("LoRa: Auto-connected to #{port}")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("LoRa: Auto-connect failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:circuits_uart, _port, {:partial, partial}}, state) do
    # Partial line received (framing mode)
    Logger.debug("UART partial: #{inspect(partial)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    # With line framing, we get complete lines
    response = String.trim(data)
    Logger.debug("UART RX: #{inspect(response)}")

    if response != "" do
      # Notify pending caller if any
      if state.pending_response do
        GenServer.reply(state.pending_response, {:ok, response})
      end

      # Broadcast to subscribers (for LiveView updates)
      broadcast_response(response, state.subscribers)

      # Handle async responses like "radio_rx <hex>"
      handle_async_response(response)

      {:noreply, %{state | pending_response: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.error("LoRa UART error: #{inspect(reason)}")
    broadcast_event({:error, reason}, state.subscribers)
    {:noreply, %{state | connected: false}}
  end

  @impl true
  def handle_call({:connect, port}, _from, state) do
    case do_connect(port, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:disconnect, _from, state) do
    if state.uart do
      Circuits.UART.close(state.uart)
    end

    {:reply, :ok, %{state | uart: nil, port: nil, connected: false}}
  end

  @impl true
  def handle_call({:send_command, cmd}, from, state) do
    if state.connected do
      Logger.debug("UART TX: #{inspect(cmd)}")
      # RN2903 expects commands terminated with CRLF
      Circuits.UART.write(state.uart, "#{cmd}\r\n")
      {:noreply, %{state | pending_response: from}}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      connected: state.connected,
      port: state.port
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  # Private functions

  defp do_connect(port, state) do
    # Close existing connection if any
    if state.uart do
      Circuits.UART.close(state.uart)
    end

    {:ok, uart} = Circuits.UART.start_link()

    # RN2903 settings: 57600 baud, 8N1, no flow control, CRLF line endings
    uart_opts = [
      speed: @default_baud,
      data_bits: 8,
      stop_bits: 1,
      parity: :none,
      flow_control: :none,
      active: true,
      framing: {Circuits.UART.Framing.Line, separator: "\r\n"}
    ]

    case Circuits.UART.open(uart, port, uart_opts) do
      :ok ->
        # Flush any pending data and send wake-up sequence
        Circuits.UART.flush(uart)
        Circuits.UART.write(uart, "\r\n\r\n")
        Process.sleep(200)
        Circuits.UART.flush(uart)

        {:ok, %{state | uart: uart, port: port, connected: true, buffer: ""}}

      {:error, reason} ->
        Circuits.UART.stop(uart)
        {:error, reason}
    end
  end

  defp broadcast_response(response, subscribers) do
    for pid <- subscribers do
      send(pid, {:lora_response, response})
    end
  end

  defp broadcast_event(event, subscribers) do
    for pid <- subscribers do
      send(pid, {:lora_event, event})
    end
  end

  defp handle_async_response("radio_rx " <> hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, data} ->
        D2dDemo.FileLogger.log_rx(data, hex)
        Phoenix.PubSub.broadcast(D2dDemo.PubSub, "lora:rx", {:lora_rx, data})

      :error ->
        Logger.warning("Invalid RX hex data: #{hex}")
    end
  end

  defp handle_async_response("radio_tx_ok") do
    D2dDemo.FileLogger.log_event(:tx_ok)
    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "lora:tx", :tx_ok)
  end

  defp handle_async_response("radio_err") do
    D2dDemo.FileLogger.log_event(:tx_error)
    Phoenix.PubSub.broadcast(D2dDemo.PubSub, "lora:tx", :tx_error)
  end

  defp handle_async_response(_other), do: :ok
end

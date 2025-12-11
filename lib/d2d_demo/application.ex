defmodule D2dDemo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      D2dDemoWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:d2d_demo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: D2dDemo.PubSub},
      # File logging for field data collection
      D2dDemo.FileLogger,
      # LoRa serial communication
      D2dDemo.LoRa,
      # LoRa test modes
      D2dDemo.Beacon,
      D2dDemo.Ping,
      # Network modules (WiFi, Bluetooth, Test Runner)
      D2dDemo.Network.WiFi,
      D2dDemo.Network.Bluetooth,
      D2dDemo.Network.TestRunner,
      # Start to serve requests, typically the last entry
      D2dDemoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: D2dDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    D2dDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

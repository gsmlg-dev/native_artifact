defmodule NativeArtifact.MixProject do
  use Mix.Project

  def project do
    [
      app: :native_artifact,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [{:http_fetch, "~> 0.21.19", runtime: false}]
    ]
  end

  def application, do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end

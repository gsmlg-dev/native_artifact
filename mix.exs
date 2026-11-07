defmodule NativeArtifact.MixProject do
  use Mix.Project

  def project do
    [
      app: :native_artifact,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [
        {:http_fetch, "~> 0.21.19", runtime: false},
        {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
      ],
      description: "Unified precompiled NIF bundle contract for Elixir",
      package: package(),
      docs: docs()
    ]
  end

  def application, do: []

  defp docs do
    [
      main: "README",
      extras: ["README.md"],
      source_url: "https://github.com/gsmlg-dev/native_artifact"
    ]
  end

  defp package do
    [
      name: "native_artifact",
      files: [
        "lib",
        "native",
        "mix.exs",
        "README.md",
        "LICENSE"
      ],
      maintainers: ["Jonathan Gao"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/gsmlg-dev/native_artifact"
      }
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end

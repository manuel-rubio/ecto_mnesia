defmodule EctoMnesia.Mixfile do
  use Mix.Project

  @version "0.10.0"

  def project do
    [
      app: :ecto_mnesia,
      description: "Ecto adapter for Mnesia erlang term storage.",
      package: package(),
      version: @version,
      elixir: "~> 1.10",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [source_ref: "v#\{@version\}", main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:decimal, "~> 2.0"},
      {:ecto_sql, "~> 3.8"},
      {:ex_doc, "~> 0.28", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      contributors: ["Maxim Sokhatsky (5ht)", "Nebo #15", "Manuel Rubio"],
      maintainers: ["Manuel Rubio"],
      licenses: ["MIT"],
      links: %{github: "https://github.com/manuel-rubio/ecto_mnesia"},
      files: ~w(lib LICENSE.md mix.exs README.md)
    ]
  end
end

defmodule ExWebp.MixProject do
  use Mix.Project

  @version "0.1.3"

  def project do
    [
      app: :ex_webp,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      maintainers: ["Morten Lund, originally Ryo Okamoto"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/ryochin/thumbp"},
      files: ~w(mix.exs README.md lib native checksum-*.exs .formatter.exs)
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler_precompiled, "~> 0.7"},
      {:rustler, "~> 0.30.0", optional: true}
    ]
  end
end

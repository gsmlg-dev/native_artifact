defmodule NativeArtifact do
  @moduledoc """
  Contracts for managing precompiled NIF bundles.

  Explicit targets, bounded Manifest v1 validation and pure resolution/planning
  and verified local installation are implemented. Plans perform no I/O; local
  execution revalidates their complete snapshots. Downloads, caches, source build
  execution and Mix integration remain pending. No platform has completed runtime
  certification.
  """

  @doc "Builds a pure, inspectable plan from pinned metadata and explicit evidence."
  @spec plan(term(), keyword()) ::
          {:ok, NativeArtifact.Plan.t()} | {:error, NativeArtifact.Error.t()}
  def plan(manifest, opts \\ []), do: NativeArtifact.Plan.new(manifest, opts)

  @doc """
  Executes a consistent precompiled plan using supplied local archive bytes.

  Required `:archive_path` and `:priv_dir` are normalized absolute local paths;
  `:priv_dir` must be an existing physical application-owned directory. Optional
  `:archive_limits` and `:timeout` are forwarded to the local Installer. Selection,
  mode and manifest limits come only from the freshly revalidated plan. Source
  plans return `:source_execution_pending` without filesystem/build/network work.
  """
  @spec install(NativeArtifact.Plan.t(), keyword()) ::
          {:ok, map()} | {:error, NativeArtifact.Error.t()}
  def install(plan, opts \\ []) do
    with {:ok, config} <-
           NativeArtifact.Resolver.Input.options(opts, [
             :archive_path,
             :priv_dir,
             :archive_limits,
             :timeout
           ]),
         :ok <- execution_options(config),
         {:ok, fresh} <- NativeArtifact.Plan.revalidate(plan) do
      case fresh.mode do
        :source ->
          {:error,
           NativeArtifact.Error.new(:invalid_configuration, %{
             stage: :installation,
             reason: :source_execution_pending
           })}

        :precompiled ->
          with :ok <- required_path(config, :archive_path),
               :ok <- required_path(config, :priv_dir) do
            NativeArtifact.Installer.install(
              fresh.manifest,
              fresh.artifact_id,
              config.archive_path,
              priv_dir: config.priv_dir,
              manifest_limits: fresh.manifest_limits,
              archive_limits: Map.get(config, :archive_limits, []),
              timeout: Map.get(config, :timeout, 180_000)
            )
          end
      end
    end
  end

  defp execution_options(config) do
    timeout = Map.get(config, :timeout, 180_000)

    with true <- is_integer(timeout) and timeout > 0,
         {:ok, limits} <-
           NativeArtifact.Resolver.Input.options(
             Map.get(config, :archive_limits, []),
             Map.keys(NativeArtifact.Archive.default_limits())
           ),
         true <- Enum.all?(limits, fn {_key, value} -> is_integer(value) and value > 0 end),
         :ok <- optional_path(config, :archive_path) do
      optional_path(config, :priv_dir)
    else
      false -> NativeArtifact.Resolver.Input.invalid(:installation, :invalid_limits)
      error -> error
    end
  end

  defp optional_path(config, field) do
    case Map.fetch(config, field) do
      :error ->
        :ok

      {:ok, path} ->
        valid =
          is_binary(path) and byte_size(path) in 1..4096 and String.valid?(path) and
            String.starts_with?(path, "/") and not Regex.match?(~r/[\x00-\x1f\x7f]/, path) and
            (path == "/" or Enum.all?(tl(String.split(path, "/")), &(&1 not in ["", ".", ".."])))

        if valid, do: :ok, else: NativeArtifact.Resolver.Input.invalid(field, :invalid_local_path)
    end
  end

  defp required_path(config, field) do
    if Map.has_key?(config, field),
      do: :ok,
      else: NativeArtifact.Resolver.Input.invalid(field, :required_local_path)
  end
end
